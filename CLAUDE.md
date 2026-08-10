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
- Notarising for distribution to other machines would need Xcode
  (`notarytool`). Ad-hoc signing is all that's needed to run it here.
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
