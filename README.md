# Context

A Markdown reader for macOS. One column, a fixed measure, system type — the
editor is a guest you summon with `⌘E` and dismiss when you're done.

Native SwiftUI shell around a WKWebView preview. 1.9 MB installed; no Xcode
required to build it.

## Install

**Requirements:** macOS 14 or later, Apple Silicon. The build targets `arm64`
only; for an Intel Mac change `-target` in `build.sh`, or make it a universal
binary. Neither is tested here.

### From a release

Unzip `Context-0.1.0.zip` and drag `Context.app` to `/Applications`.

Context is **ad-hoc signed and not notarised** — there is no paid Apple
Developer ID behind it — so macOS blocks the first launch outright, with a
dialog saying it cannot verify the app is free of malware. Getting past that is
a deliberate choice you have to make, and on macOS 15 and later it is made here:

1. Try to open the app once. Dismiss the warning.
2. **System Settings → Privacy & Security**, scroll down to Security, and click
   **Open Anyway** on the message about Context.
3. Confirm. It opens, and every launch after that is ordinary.

Control-clicking the app and choosing Open used to do this in one step. macOS 15
removed that route for apps that aren't notarised, so anyone still repeating that
advice — including older copies of this README — is giving you instructions that
no longer work.

The same decision from a terminal, if you prefer it:

```sh
xattr -d com.apple.quarantine /Applications/Context.app
```

Either way you are waiving Gatekeeper's check on *where the app came from*, not
on whether it is intact. The signature is untouched, and you can say so yourself
before you trust it:

```sh
codesign --verify --deep --strict --verbose=2 /Applications/Context.app
spctl -a -vvv /Applications/Context.app     # "rejected" — no Developer ID, as documented
```

### From source

```sh
npm install     # once
./build.sh      # → build/Context.app, build/Context-0.1.0.zip
cp -R build/Context.app /Applications/
```

Needs the Command Line Tools (`swiftc`) and Node — **not** Xcode. `build.sh`
bundles the web assets with esbuild, compiles the Swift, assembles the bundle by
hand, ad-hoc signs it, and packages the zip.

Nothing you build yourself is quarantined, so this path shows no warning at all —
it is the shorter road if you have the tools already.

## Keys

| | |
|---|---|
| `⌘O` | Open a file (or drop one on the window) |
| `⌘E` | Show/hide the editor pane |
| `⌘F` | Find — the reading pane, or the editor if you are typing in it |
| `⌘G` `⇧⌘G` | Next / previous match |
| `⌘S` | Save |
| `⇧⌘R` | Reveal in Finder |
| `⌘+` `⌘-` `⌘0` | Text size |

## What it does

- **GFM** via markdown-it — tables, task lists, footnotes, strikethrough
- **Maths** via KaTeX, `$inline$` and `$$display$$`
- **Syntax highlighting** for 27 languages, Julia included
- **Find** that searches the page as it reads, not as it is marked up — a phrase
  matches across emphasis and across a hard-wrapped line, and a formula's TeX
  source is not text you can land on. Matches survive a reload of the file.
- **Follows the system** between light and dark
- **Watches the open file** and re-renders on save, keeping your scroll
  position — so it works as a live preview for whatever editor you actually use.
  Unsaved edits in Context's own editor are never overwritten by a disk change.
- **Relative links and images** resolve against the document's folder; a
  relative link to another `.md` opens it in Context — at the right section if
  the link names one — and everything else goes to whichever app owns it.
- **Links within the page** work as they do in a browser: a link to a heading,
  and a footnote and its way back.

It registers as an *alternate* handler for `.md` — Context shows up in "Open
With" without taking over every Markdown file on the machine. Set it as the
default yourself in Finder if you want that.

## Opening documents other people wrote

A Markdown file is untrusted input — it came from a repo you cloned or a
colleague's message — so the reading pane is closed down rather than open by
default:

- Nothing in a document can execute script, enforced by a Content-Security-Policy
  rather than by trusting the Markdown.
- **Nothing in a document reaches the network.** No remote images, so a file
  cannot report that you opened it. The visible cost is that badges and other
  externally hosted images show as broken — that is the trade, and it is
  deliberate.
- A document cannot navigate the pane anywhere. Only a link you click does.
- A link to a local file opens it only when opening merely *shows* it. Anything
  that would run — an app, a `.command`, an installer, a configuration profile —
  is revealed in the Finder instead, and the banner tells you why.

None of this replaces judgement about what you open, and Context is a reader, not
a sandbox. But a document you were sent cannot act on your machine by being read.

## Layout

```
Sources/       Swift — app, document model + file watcher, the two panes, find
Web/           index.html, style.css, preview-entry.js + find.js (→ preview.js)
Tools/         dev-only: snapshot renderer, icon generator
Resources/     AppIcon.icns, generated by Tools/MakeIcon.swift
build.sh       the whole build
Sample.md      fixture exercising every construct
CLAUDE.md      engineering notes — the non-obvious bits, and why
```

Prose sits in a centre grid track at the reading measure; code blocks, tables
and display maths get a wider track so they breathe without stretching the
line length of the prose.

## Licence

MIT — see `LICENSE`.

The source tree vendors no dependencies. A *built* `Context.app` embeds
markdown-it, KaTeX and highlight.js, all permissive (MIT / ISC / BSD-3-Clause);
`THIRD-PARTY-NOTICES.md` carries their notices and must ship alongside any
binary you distribute.

## Not yet

Single window, one document at a time — open several and Context takes the first
and tells you so. No outline sidebar, no PDF export, no scroll sync between the
panes. Find is plain text — no regular expressions, no case-sensitive or
whole-word toggle.
