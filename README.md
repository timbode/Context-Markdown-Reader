# Quire

A Markdown reader for macOS. One column, a fixed measure, system type — the
editor is a guest you summon with `⌘E` and dismiss when you're done.

Native SwiftUI shell around a WKWebView preview. 1.7 MB installed; no Xcode
required to build it.

## Build

```sh
npm install     # once
./build.sh      # → build/Quire.app
```

Needs the Command Line Tools (`swiftc`) and Node. `build.sh` bundles the web
assets with esbuild, compiles the Swift, assembles the bundle by hand, and
ad-hoc signs it.

Install with `cp -R build/Quire.app /Applications/`.

## Keys

| | |
|---|---|
| `⌘O` | Open a file (or drop one on the window) |
| `⌘E` | Show/hide the editor pane |
| `⌘S` | Save |
| `⇧⌘R` | Reveal in Finder |
| `⌘+` `⌘-` `⌘0` | Text size |

## What it does

- **GFM** via markdown-it — tables, task lists, footnotes, strikethrough
- **Maths** via KaTeX, `$inline$` and `$$display$$`
- **Syntax highlighting** for 27 languages, Julia included
- **Follows the system** between light and dark
- **Watches the open file** and re-renders on save, keeping your scroll
  position — so it works as a live preview for whatever editor you actually use.
  Unsaved edits in Quire's own editor are never overwritten by a disk change.
- **Relative links and images** resolve against the document's folder; a
  relative link to another `.md` opens it in Quire, everything else goes to
  whichever app owns it.

It registers as an *alternate* handler for `.md` — Quire shows up in "Open
With" without taking over every Markdown file on the machine. Set it as the
default yourself in Finder if you want that.

## Layout

```
Sources/       Swift — app, document model + file watcher, the two panes
Web/           index.html, style.css, preview-entry.js (bundled to preview.js)
Tools/         dev-only: snapshot renderer, icon generator
build.sh       the whole build
Sample.md      fixture exercising every construct
```

Prose sits in a centre grid track at the reading measure; code blocks, tables
and display maths get a wider track so they breathe without stretching the
line length of the prose.

## Not yet

Single window (one document at a time), no outline sidebar, no PDF export, no
scroll sync between the panes.
