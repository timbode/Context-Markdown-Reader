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

⌘-clicking either kind opens the file in a new tab instead, and that one *does*
lose the fragment: `pendingAnchor` belongs to the pane doing the navigating and
cannot reach a webview that does not exist yet.

`renderBase64` keeps the reading position **only when the file is the same one**,
which is why `render` takes a URL it otherwise has no use for. Preserving it
unconditionally is the obvious-looking bug: following a link from 1200px down
left you 1200px into a document you had never seen.

## A document is untrusted input

Markdown arrives from other people — a repo you cloned, a file a colleague sent.
The reading pane is therefore where somebody else's content meets your machine.
Three things were measured against a deliberately hostile fixture, and all three
were real before they were fixed:

- **`<img onerror=…>` executed.** Raw HTML is on (`html: true`), and `innerHTML`
  does *not* run `<script>` but does fire event handlers. Arbitrary JavaScript,
  from opening a file.
- **The page could phone home.** `<img src="http://…">` fired on render with no
  script at all — a tracking pixel in a Markdown file — and script could put data
  in the query string. A local listener logged the `?leak=…` arriving.
- **A scripted navigation escaped.** `decidePolicyFor` inspected only
  `.linkActivated`, so `location.href = 'https://…'` fell through to `.allow` and
  replaced the reader with a live remote page, in a window with no address bar to
  give it away.

What was never possible, and still is not: reading local files back into script.
`fetch` is blocked, an iframe or `<object>` on the custom scheme is cross-origin
(`contentDocument` is null), and a local image taints a canvas — `getImageData`
throws `SecurityError`. WebKit's origin model holds. So none of the above reached
your files; they reached the fact that you opened a document, and the pixels in
front of you.

Two controls now stand in the way, and **both are load-bearing**:

1. **The CSP in `Web/index.html`.** `script-src 'self'` kills inline handlers;
   the absence of any remote source kills beacons. Verified: `inlineHandlerRan`
   goes true → false and the listener receives nothing. Verified also to cost
   nothing — KaTeX (135 inline style attributes), highlight.js, the webfonts and
   the find bridge produce byte-identical numbers with it and without it.
2. **Deny-by-default in `decidePolicyFor`.** Only a click, or the bundled page
   itself, may navigate; everything else is cancelled.

They are independent on purpose. `evaluateJavaScript` from the Swift side is not
subject to the CSP — which is why the bridge still works, and why a probe can
still simulate script execution to test the second control with the first one
neutralised.

## Clicking a link must never run anything

`NSWorkspace.open` on a resolved link was one click from code execution: a
`.command` beside the document runs in Terminal, and a file that arrived by `git
clone` carries no quarantine, so Gatekeeper never sees it. Measured — a cloned
`.command` has only `com.apple.provenance`, and keeps its execute bit.

Non-Markdown links now go through `isInert`, which opens only types on a narrow
allowlist and reveals everything else in the Finder. Conformance is untrustworthy
in both directions, and the list was narrowed twice by measurement, not reading:

- `.command` is `public.shell-script` → `public.script` → `public.plain-text`, so
  an allowlist naming plain text waves it straight through.
- `.pkg` conforms to `public.archive`.
- `.mobileconfig` conforms to `public.xml`, and carries certificates or MDM
  enrolment.

Hence `public.archive` and `public.xml` are absent from the allowlist, and the two
identifiers with no `UTType` constant are named as strings. When changing either
list, re-run the type probe over a directory of real files rather than reasoning
about the graph — that is how both holes were found, and reading found neither.

## Tabs are windows, and SwiftUI keeps making extra ones

A macOS tab group is several `NSWindow`s stacked under one title bar, so the
tabbed app *is* the multi-window app: `WindowGroup(id:for: URL.self)`, one
`Document` and one `FindModel` per window, menu commands reading
`@FocusedValue`. `WindowRouter` is the one thing on top — it holds the register
of live tabs and answers an open request one of three ways: raise the tab that
already has the file, fill a tab that has nothing in it, or make one.

Six things about this are not guessable from the docs. Every one was measured,
and all but the first were bugs before they were findings.

- **`openWindow` does not make a tab.** `tabbingMode = .preferred` is set on
  every window and is not enough; the new window comes up beside the group.
  `addTabbedWindow` is what puts it in, and it needs a *host* to join — captured
  in `WindowRouter.open` at the moment the window is asked for, because by the
  time the window appears it is itself key and the answer is gone. Restored
  windows have no host at all, so `attach` falls back to any window already
  registered.

- **SwiftUI answers the open-documents Apple Event by opening a blank window.**
  It cannot turn a file into the group's `URL` value, so it opens the group's
  *default* window and then calls `application(_:open:)`, which opens the file
  properly — one stray blank tab per file. The blank window is adopted *before*
  the delegate method runs, which is how this was pinned down. `AppDelegate`
  therefore takes the `kAEOpenDocuments` handler over itself — but only once the
  app is up, for the reason two bullets below. Both routes end at
  `WindowRouter.open`, so `application(_:open:)` is still there and still needed:
  it is what serves the launch.

- **`applicationShouldHandleReopen` must return `!flag`.** Returning true
  unconditionally is right for a single-window app and costs a blank tab every
  time the app is activated from the Dock or by `open -a`.

- **A restore brings back the group's windows *and* opens the default one**, so
  a session that ended with an empty tab comes back with two, and the count
  climbs by one per launch. Nothing distinguishes a restored window from a fresh
  one, hence the sweep inside `settleAfterLaunch()`, on a short delay — a timer
  because there is no "restoration finished" hook. It also drops duplicate tabs
  on one file: nothing can *make* one, but a session that once had one restores
  it for good, with two watchers on a single path.

- **`WKNavigationAction.modifierFlags` is empty.** A ⌘-click arrives as a plain
  `.linkActivated` with flags of 0, so the documented way to implement
  open-in-new-tab silently does nothing. Measured with a synthetic `MouseEvent`
  carrying `metaKey`. It does not go to `WKUIDelegate` either;
  `createWebViewWith` is for `window.open` and is never called.
  `isCommandHeld(during:)` therefore consults both the action's flags and
  `NSEvent.modifierFlags`, the second being the keyboard itself, still true a
  moment after the mouse-up.

- **Nothing opens at all if the Apple Event is taken over too early.** On a
  launch driven by documents — double-clicking a `.md` while Context is closed —
  SwiftUI does not open its default window: it expects the document handler to
  make the windows. Take the event away in `applicationWillFinishLaunching` and
  there is never a window, so nothing ever hands `WindowRouter` an `openWindow`
  to call, and the file sits in `deferred` forever behind an app with an empty
  screen. Hence `takeOverOpenDocuments()` runs a second *after* launch: the
  launch itself keeps AppKit's handler, and its one stray blank tab is swept by
  the same timer.

- **A file asked for during launch cannot be answered during launch.** "Is this
  one already open?" has no answer while restoration is still bringing tabs back,
  and answering it anyway costs a second tab on a file that was about to
  reappear. The symptom is horrible to chase, because it strikes only the file
  whose restored tab happens to come back *last* — four files out of five look
  fine. So `WindowRouter` queues every request until `settleAfterLaunch()`, and a
  tab is registered with the file it is *going to* show (`Tab.intended`) rather
  than only the one it has already read: a restored tab is empty for the moment
  between appearing and loading, and would otherwise be taken for a free one.

Watch out for one more thing across all of this: **`==` on two file URLs is not
"same file"**. A link resolved against the document's folder compares unequal to
the same path from the Finder even after `.standardizedFileURL.absoluteURL`, and
`/tmp` and `/private/tmp` spell one file two ways. Measured, and it was a real
bug: a ⌘-clicked link opened a second tab on a document already in one.
`WindowRouter.isSameFile` normalises with `resolvingSymlinksInPath()`, and is
what every "is this already open?" question has to go through.

Where that restoration state lives is worth knowing you *cannot* find: it is not
in `~/Library/Saved Application State` (no such directory on this machine), not
in the preferences plist, not in the recent-documents `.sfl3`. To test a
first-ever launch, build with a different `BUNDLE_ID` — that is the only reliable
clean slate.

**Test the app the way it is launched.** Running
`build/Context.app/Contents/MacOS/Context` by hand and then sending it files with
`open -a` exercises a different path from double-clicking a document with the app
closed — and the second was completely broken while every test passed, because no
test ever cold-launched it. `open -a <bundle> <file>` with nothing running is
the case that matters. Check `/Applications/Context.app`'s date before believing
a report about behaviour, too: an installed copy is what gets clicked, and
`build.sh` does not update it.

Testing any of this from a terminal session needs a trick, because System Events
is refused (`osascript is not allowed assistive access`), so window counts and
tab groups cannot be read from outside. Instrument instead, with an env-gated
`probe`, and note that **an app launched by `open` has no stderr you can read** —
write to a file. `NSApp.windows` with each window's `title`, `isVisible` and
`tabGroup` identity tells you the whole story; that is how the nine-window launch
was diagnosed.

Two cheaper checks, worth knowing because they need no build at all. `lsof -p
$(pgrep -x Context) | grep '\.md'` lists one descriptor per open tab, the file
watcher's — so duplicate tabs and tabs that failed to open are both visible
without a probe, though the descriptors lag a closed tab by a few seconds. And
`ps` tells you *which bundle* is running, which is how the stale
`/Applications` copy was caught.

Beware `: > log` while the process holds the file open: the offset survives, so
grep sees a binary hole and prints nothing.

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
- **One tab, one document** — see "Tabs are windows" above. `@AppStorage` for
  zoom and editor width is deliberately shared across tabs.
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
