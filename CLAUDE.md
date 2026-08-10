# Notes for future sessions

Things that are not obvious from the code, and that cost time to work out.

## No Xcode on this machine — only Command Line Tools

`xcodebuild` does not exist here; `swiftc` does, and the CLT ships the full
macOS SDK including SwiftUI, AppKit and WebKit. So the whole build is
`swiftc` + a hand-assembled bundle in `build.sh`. Don't reach for an
`.xcodeproj` or a `Package.swift` app target — nothing would run it.

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

## Screen Recording permission is not granted to the shell

`screencapture` fails for windows, regions *and* full screen — "could not
create image from …". So the native chrome (title bar, editor pane, split)
cannot be screenshotted from a session.

`Tools/Snapshot.swift` works around this for the part that matters: it loads
the app's own web assets into an offscreen WKWebView, renders a Markdown file,
and writes PNGs. No permission needed, because the app is capturing itself.

```sh
swiftc -O -o build/tools/snapshot Tools/Snapshot.swift
./build/tools/snapshot build/Quire.app/Contents/Resources/app Sample.md build/light.png 940 light 860
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
lsof -p $(pgrep -x Quire) | grep Sample.md   # NODE column
stat -f %i Sample.md                          # must match
```

Mismatch means the watcher is holding a descriptor on the old unlinked inode
and external reloads have silently stopped working.

`Document.isSavingOurselves` suppresses the event from Quire's own writes.
Disk changes never clobber unsaved edits — the reload is skipped and a status
message says so.

## Deliberate choices, not oversights

- `LSHandlerRank` is `Alternate`, so Quire does not take over `.md` system-wide.
- Only KaTeX's `.woff2` fonts ship; `.woff`/`.ttf` are listed later in its
  `@font-face` stacks and WebKit never asks for them. Saves ~3.8 MB.
- Markdown is passed to JS base64-encoded so no escaping games are needed
  across the `evaluateJavaScript` bridge.
- Type is entirely system-supplied (`ui-serif` → New York, `ui-sans-serif` →
  SF Pro, `ui-monospace` → SF Mono). Nothing is bundled or downloaded. Verified
  rendering correctly inside WKWebView.
