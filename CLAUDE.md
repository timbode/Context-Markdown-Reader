# Notes for future sessions

Things that are not obvious from the code, and that cost time to work out.

## The build assumes Command Line Tools only — no Xcode

`xcodebuild` is not available; `swiftc` is, and the CLT ships the full macOS SDK
including SwiftUI, AppKit and WebKit. So the whole build is `swiftc` + a
hand-assembled bundle in `build.sh`. Don't reach for an `.xcodeproj` or a
`Package.swift` app target — nothing here would run it.

Consequences:
- The app icon can't come from an asset catalog (`actool` is Xcode-only).
  `Tools/MakeIcon.swift` draws it with Core Graphics and `iconutil` packs the
  `.iconset`. Regenerate with:
  `swiftc -O -o build/tools/makeicon Tools/MakeIcon.swift && ./build/tools/makeicon build/AppIcon.iconset && iconutil --convert icns --output Resources/AppIcon.icns build/AppIcon.iconset`
- Notarising does **not** need Xcode, contrary to the obvious guess:
  `notarytool` and `stapler` both ship in the Command Line Tools. What is
  missing is a Developer ID certificate — `security find-identity -v -p
  codesigning` finds none — so there is nothing to sign with and ad-hoc is as
  far as this build reaches. Buying into the Developer Program is the whole of
  the remaining work; the tooling is already here.
- `swiftc` defaults to Swift 5 language mode, so strict concurrency is not
  enforced. That's why `MainActor.assumeIsolated` appears in delegate
  callbacks rather than a full actor-isolation refactor.

## `-module-name` is load-bearing

`build.sh` passes `-module-name ContextReader`. Do not drop it and do not change
it to `Context`. Without it, swiftc names the module after the output binary —
`Context` — and a module of that name shadows the `Context` typealias that
`NSViewRepresentable` hands to every `makeNSView(context:)` / `updateNSView`.
The whole target then fails with "cannot use module 'Context' as a type".

The trap when checking this: compiling with `-o /dev/null` derives a *different*
module name and succeeds, so a quick syntax check will not reproduce it. Test
with the real output path, or just run `./build.sh`.

## What ad-hoc signing costs the people you send it to

`spctl -a` rejects the app — signed or not — because the signature carries no
Developer ID. That verdict only bites on a copy that is *quarantined*, which is
the attribute a browser writes on download. Hence the asymmetry the README is
built around: a locally built app launches with no prompt at all, and a
downloaded one is refused outright.

**macOS 15 removed the Control-click-and-Open override** for apps that aren't
notarised. The route is now System Settings → Privacy & Security → Open Anyway,
or `xattr -d com.apple.quarantine`. Any instruction still naming the old one is
stale; check the README stays in step if Apple moves it again.

The release zip is built with `ditto -c -k --keepParent`, not `zip`. A bundle
carries a signature and extended attributes that plain `zip` does not preserve,
and an archive arriving with a broken seal is worse than none. Verified: after a
ditto round-trip `codesign --verify --deep --strict` reports "valid on disk" and
"satisfies its Designated Requirement".

To check any of this without waiting for someone to complain, quarantine a copy
by hand — the bit is not magic:

```sh
xattr -w com.apple.quarantine "0083;68a0000;Safari;" /path/to/Context.app
spctl -a -vvv --type execute /path/to/Context.app
```

## Screenshots need Screen Recording permission — the snapshot tool does not

Without it `screencapture` fails for windows, regions *and* full screen ("could
not create image from …"), so the native chrome (title bar, editor pane, split)
cannot be captured from a terminal session at all.

`Tools/Snapshot.swift` works around this for the part that matters: it loads
the app's own web assets into an offscreen WKWebView, renders a Markdown file,
and writes PNGs. No permission needed, because the app is capturing itself.

```sh
swiftc -O -o build/tools/snapshot Tools/Snapshot.swift
./build/tools/snapshot build/Context.app/Contents/Resources/app Sample.md build/light.png 940 light 860
```

Last arg is a slice height — tall documents come out as `light-00.png`,
`light-01.png`, … because a full-page PNG scaled down is unreadable. The
`light`/`dark` argument sets `data-theme` on `<html>`, so the snapshot doesn't
depend on the machine's current appearance.

If the native window ever needs reviewing, Screen Recording has to be granted
to the terminal in System Settings → Privacy & Security first.

## Markup quirks that caused real bugs

- **markdown-it-texmath** emits `<eq>` for inline maths and
  `<section><eqn>…</eqn></section>` for display. The footnote plugin *also*
  emits a `<section>`, so the "wide grid track" rule has to be
  `#doc > section:not(.footnotes)` — otherwise footnotes render outdented from
  the prose.
- **markdown-it-footnote** puts its separator rule *outside* the section, as
  `<hr class="footnotes-sep">`. `.footnotes hr` does not match it. Hiding it
  needs `hr.footnotes-sep`.
- **markdown-it-task-lists** with `label: true` nests the checkbox and the text
  inside a single `<label>`, so the `<li>` has one flex child and `gap` on the
  `<li>` does nothing. The `<label>` is the flex container.
- **KaTeX emits every formula twice**: the visible HTML, and a MathML copy
  holding the TeX source, clipped to a 1px box for accessibility. So
  `textContent` contains `\begin{bmatrix}` and `\sqrt` even though nothing on
  the page says either. Anything walking the document's text has to skip
  `.katex-mathml`, or it finds equations by their source and points at nothing.
- **KaTeX sets `\text{a b}` with a non-breaking space**, so the rendered text is
  not the text a reader would type.

## Find matches what the page looks like, not what it is made of

`Web/find.js` flattens the document to one string and matches against that. Four
things stand between the two, and each cost a debugging round:

- Source is hard-wrapped, and those newlines survive into the text node — a
  phrase crossing one holds `\n` where the reader sees a space.
- The typographer has already turned quotes curly and `--` into a dash.
- KaTeX and `&nbsp;` put non-breaking spaces in visible text.
- Matches cross inline markup (`hello *world*` is three text nodes) but must not
  cross a block boundary, or two paragraphs join into a word that is nowhere on
  the page.

So text nodes are concatenated, `\n` is inserted between blocks, and everything
else is folded — **strictly one character for one**, because offsets into the
folded string index back into the original nodes. Any fold that changes a length
silently shifts every match after it.

Matches are painted with the CSS Custom Highlight API rather than wrapped in
elements: wrapping would restyle the grid and would have to be unpicked before
the next render. That API needs Safari 17.2, i.e. macOS 14.2 — below it
`::highlight()` is dropped and `find.js` falls back to the selection.

Ranges point at nodes, so **every render invalidates them**. `PreviewView.push`
calls `FindModel.refresh()` right after `renderBase64`; WebKit runs the two in
the order they were queued.

## Margins never collapse inside `#doc`

`#doc` is a grid, and grid items' margins do not collapse. Every vertical gap
in the document is therefore the **sum** of both neighbours' margins, not the
larger of the two — the opposite of normal flow, and the reason horizontal
rules once sat 71px below a paragraph and 117px above the next heading.

So when spacing anything in `style.css`, ask what the *other* side contributes.
Where an element needs a predictable gap, have it own both sides and zero its
neighbours' (`hr` does this via `:has(+ hr)` / `hr + *`) rather than tuning two
numbers against each other.

Measure rather than eyeball: render with `Tools/Snapshot.swift` and scan the PNG
for rows containing ink; the gaps between those bands are the real numbers.

## Two kinds of link, and only one of them is a navigation

`[x](#heading)` really navigates: WebKit scrolls it, and `decidePolicyFor` only
has to allow it. `[x](other.md#heading)` does not navigate at all — the document
is replaced under the same page URL — so nothing scrolls by itself. The fragment
has to be carried across the hop by hand (`Coordinator.pendingAnchor`) and spent
once the new text is on screen, because `resolve` deals in file paths and drops
it. Both land with the same air above the heading, via `scroll-margin-top` on
`#doc [id]`, which `scrollIntoView` and WebKit's own scroll both honour.

`renderBase64` keeps the reading position **only when the file is the same one**,
which is why `render` takes a URL it otherwise has no use for. Preserving it
unconditionally is the obvious-looking bug: following a link from 1200px down
left you 1200px into a document you had never seen.

## Why the panes never branch on `editorVisible`

`ContentView` keeps both panes in the tree always and collapses the editor to
`width: 0`. Writing `if editorVisible { HSplitView { … } } else { Preview }`
changes the structural position of `PreviewView`, which tears down and rebuilds
the WKWebView on every toggle — losing scroll position and re-running the whole
render. Same reason the window title is set through `WindowAccessor` in a
`.background()` rather than a conditional `.navigationDocument()`.

## File watching

`FileWatcher` re-arms on `.rename`/`.delete` rather than treating the file as
gone, because most editors save atomically (write temp, rename over), which
kills a plain vnode source. Verify a change to it with:

```sh
lsof -p $(pgrep -x Context) | grep Sample.md   # NODE column
stat -f %i Sample.md                          # must match
```

Mismatch means the watcher is holding a descriptor on the old unlinked inode
and external reloads have silently stopped working.

`Document.isSavingOurselves` suppresses the event from Context's own writes.
Disk changes never clobber unsaved edits — the reload is skipped and a status
message says so.

## Deliberate choices, not oversights

- `LSHandlerRank` is `Alternate`, so Context does not take over `.md` system-wide.
- **One window, one document** — a `Window` scene rather than a `WindowGroup`,
  with `Document` and `FindModel` as singletons. A v0.1 decision, not a belief
  about how a reader should work; opening a set takes the first and says so
  rather than dropping the rest in silence.

  Making it multi-window is contained, and worth knowing the shape of before
  starting: `WindowGroup(for: URL.self)`; one `Document` and one `FindModel` per
  window instead of `.shared`; menu commands reading `@FocusedValue` rather than
  the singletons, so they act on the focused window; `application(open:)`
  opening a window per URL. The file watcher needs nothing — it already lives on
  the document and would follow it. `@AppStorage` for zoom and editor width
  would become shared across windows, which is probably what you want anyway.
- The Swift target is `arm64` only, not universal. Nothing depends on that
  beyond the machine it was written on; widening it is a one-line change to
  `-target` in `build.sh` (or two builds and `lipo`).
- Only KaTeX's `.woff2` fonts ship; `.woff`/`.ttf` are listed later in its
  `@font-face` stacks and WebKit never asks for them. Saves ~3.8 MB.
- Markdown is passed to JS base64-encoded so no escaping games are needed
  across the `evaluateJavaScript` bridge.
- Type is entirely system-supplied (`ui-serif` → New York, `ui-sans-serif` →
  SF Pro, `ui-monospace` → SF Mono). Nothing is bundled or downloaded. Verified
  rendering correctly inside WKWebView.
