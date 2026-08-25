// Bundled into Resources/app/preview.js by build.sh (esbuild, IIFE).
// Exposes window.Context for the Swift side to drive.

import MarkdownIt from 'markdown-it'
import footnote from 'markdown-it-footnote'
import taskLists from 'markdown-it-task-lists'
import texmath from 'markdown-it-texmath'
import katex from 'katex'

import hljs from 'highlight.js/lib/core'
import bash from 'highlight.js/lib/languages/bash'
import c from 'highlight.js/lib/languages/c'
import cpp from 'highlight.js/lib/languages/cpp'
import css from 'highlight.js/lib/languages/css'
import diff from 'highlight.js/lib/languages/diff'
import dockerfile from 'highlight.js/lib/languages/dockerfile'
import go from 'highlight.js/lib/languages/go'
import ini from 'highlight.js/lib/languages/ini'
import java from 'highlight.js/lib/languages/java'
import javascript from 'highlight.js/lib/languages/javascript'
import json from 'highlight.js/lib/languages/json'
import julia from 'highlight.js/lib/languages/julia'
import latex from 'highlight.js/lib/languages/latex'
import lua from 'highlight.js/lib/languages/lua'
import makefile from 'highlight.js/lib/languages/makefile'
import markdown from 'highlight.js/lib/languages/markdown'
import python from 'highlight.js/lib/languages/python'
import r from 'highlight.js/lib/languages/r'
import ruby from 'highlight.js/lib/languages/ruby'
import rust from 'highlight.js/lib/languages/rust'
import scss from 'highlight.js/lib/languages/scss'
import shell from 'highlight.js/lib/languages/shell'
import sql from 'highlight.js/lib/languages/sql'
import swift from 'highlight.js/lib/languages/swift'
import typescript from 'highlight.js/lib/languages/typescript'
import xml from 'highlight.js/lib/languages/xml'
import yaml from 'highlight.js/lib/languages/yaml'

import * as finder from './find.js'
import * as outline from './outline.js'

// Registered explicitly rather than pulling highlight.js's "common" bundle:
// this list is the one that ships, and it costs about a tenth of the full set.
for (const [name, lang] of Object.entries({
  bash, c, cpp, css, diff, dockerfile, go, ini, java, javascript, json, julia,
  latex, lua, makefile, markdown, python, r, ruby, rust, scss, shell, sql,
  swift, typescript, xml, yaml,
})) {
  hljs.registerLanguage(name, lang)
}

/** Fence labels people actually type, mapped to registered language names. */
const ALIASES = {
  jl: 'julia', py: 'python', js: 'javascript', ts: 'typescript', rb: 'ruby',
  rs: 'rust', sh: 'bash', zsh: 'bash', console: 'shell', yml: 'yaml',
  toml: 'ini', html: 'xml', tex: 'latex', md: 'markdown', 'c++': 'cpp',
  docker: 'dockerfile', make: 'makefile',
}

const md = new MarkdownIt({
  html: true,
  linkify: true,
  typographer: true,
  breaks: false,
  /**
   * Highlights a fenced code block.
   *
   * @param {string} str - The block's raw contents.
   * @param {string} lang - The fence's language label, possibly empty.
   * @returns {string} Highlighted HTML, or '' to let markdown-it escape the
   *   block itself — which is also the fallback for an unknown language or a
   *   highlighter that throws.
   */
  highlight(str, lang) {
    const name = ALIASES[(lang || '').toLowerCase()] || (lang || '').toLowerCase()
    if (name && hljs.getLanguage(name)) {
      try {
        return hljs.highlight(str, { language: name, ignoreIllegals: true }).value
      } catch (_) { /* fall through to escaping */ }
    }
    return ''
  },
})

md.use(footnote)
md.use(taskLists, { label: true, labelAfter: false })
md.use(texmath, {
  engine: katex,
  delimiters: 'dollars',
  katexOptions: {
    throwOnError: false,
    // Rendering errors show inline in a muted colour rather than red shouting.
    errorColor: 'var(--muted)',
    strict: false,
    trust: false,
  },
})

/**
 * Wraps top-level tables in their own scroll container.
 *
 * Tables can exceed the reading measure; the stylesheet gives the wrapper its
 * own scroll context so the page itself never scrolls sideways.
 *
 * @param {HTMLElement} root - The rendered document. Mutated in place.
 */
function wrapTables(root) {
  for (const table of root.querySelectorAll(':scope > table')) {
    const wrap = document.createElement('div')
    wrap.className = 'table-scroll'
    table.replaceWith(wrap)
    wrap.appendChild(table)
  }
}

/**
 * Marks the blocks that need a lane kept clear for a scrollbar.
 *
 * Measured rather than given to every code block, because the lane only pays
 * for itself where there is a bar: what reads badly is a block one or two lines
 * tall, where the bar lands on the text. See the stylesheet for what the class
 * buys.
 *
 * @param {HTMLElement} root - The rendered document. Mutated in place.
 */
function markScrollers(root) {
  for (const el of root.querySelectorAll('pre, .table-scroll, section')) {
    // A rounding of a fraction of a pixel is not an overflow.
    el.classList.toggle('scroll-lane', el.scrollWidth - el.clientWidth > 1)
  }
}

/**
 * Gives every heading a slug id.
 *
 * Stable ids so in-document links and future outline work have something to
 * aim at. Duplicate headings get a numeric suffix.
 *
 * @param {HTMLElement} root - The rendered document. Mutated in place.
 */
function addHeadingIds(root) {
  const seen = new Map()
  for (const h of root.querySelectorAll('h1, h2, h3, h4, h5, h6')) {
    const base = (h.textContent || '')
      .toLowerCase().trim()
      .replace(/[^\w\s-]/g, '')
      .replace(/\s+/g, '-') || 'section'
    const n = (seen.get(base) || 0) + 1
    seen.set(base, n)
    h.id = n === 1 ? base : `${base}-${n}`
  }
}

/** Matches anything already resolvable: a scheme, a protocol-relative host, or
 *  a bare fragment. */
const ABSOLUTE = /^(?:[a-z][a-z0-9+.-]*:|\/\/|#)/i

/**
 * Rewrites one relative URL attribute into the custom scheme.
 *
 * Absolute URLs and in-page fragments are left alone. A leading '/' selects the
 * 'abs' host, anything else resolves against the document's folder.
 *
 * @param {Element} el - Element carrying the attribute. Mutated in place.
 * @param {string} attr - Attribute name, 'src' or 'href'.
 */
function rewriteURL(el, attr) {
  const raw = el.getAttribute(attr)
  if (!raw || ABSOLUTE.test(raw)) return
  const [path, hash] = raw.split('#')
  if (!path) return
  const host = path.startsWith('/') ? 'abs' : 'doc'
  const clean = path.replace(/^\.\//, '').replace(/^\//, '')
  el.setAttribute(attr, `context-doc://${host}/` + encodeURI(clean) + (hash ? '#' + hash : ''))
}

/**
 * Points every relative image and link at the custom scheme.
 *
 * Relative images and links are resolved by the Swift side against the
 * document's own directory, via that scheme. Without this the webview — which
 * is loaded out of the app bundle — has no way to reach them.
 *
 * @param {HTMLElement} root - The rendered document. Mutated in place.
 */
function localizeURLs(root) {
  for (const img of root.querySelectorAll('img[src]')) rewriteURL(img, 'src')
  for (const a of root.querySelectorAll('a[href]')) rewriteURL(a, 'href')
}

/** @returns {HTMLElement} The container the rendered document lives in. */
const doc = () => document.getElementById('doc')

/**
 * Decodes base64 to a string, via bytes.
 *
 * atob alone yields one char per byte, which mangles anything non-ASCII; the
 * bytes have to be handed to a UTF-8 decoder.
 *
 * @param {string} b64 - Base64-encoded UTF-8.
 * @returns {string} The decoded text.
 */
function decodeBase64Utf8(b64) {
  const bin = atob(b64)
  const bytes = new Uint8Array(bin.length)
  for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i)
  return new TextDecoder('utf-8').decode(bytes)
}

// What overflows depends on how wide the pane is, so the marking has to be
// redone whenever that changes — dragging the split, resizing the window, or
// zooming, which alters the viewport in CSS pixels. Observing #doc catches all
// three. KaTeX's fonts also arrive after the layout that first asks for them
// and change the width of every formula, so each batch is worth another pass.
let lastWidth = 0
new ResizeObserver(entries => {
  // Width only: the marking changes the *height* of what it marks, so reacting
  // to that would have the observer wake itself for as long as WebKit tolerates.
  const width = entries[0].contentRect.width
  if (width === lastWidth) return
  lastWidth = width
  markScrollers(doc())
}).observe(doc())
document.fonts?.addEventListener('loadingdone', () => markScrollers(doc()))

// Folding changes what is on the page, and a block revealed by it has never
// been measured. `outline.apply` says so rather than every caller remembering.
doc().addEventListener('outlinechange', () => markScrollers(doc()))

/**
 * The id an in-page link points at.
 *
 * `decodeURIComponent` throws on a malformed escape, and a document is written
 * by somebody else — a link nobody can follow must not be a click that stops
 * working.
 *
 * @param {HTMLAnchorElement} link - A link with a fragment.
 * @returns {string} The fragment, decoded where it can be.
 */
function fragmentOf(link) {
  const raw = link.hash.slice(1)
  try {
    return decodeURIComponent(raw)
  } catch (_) {
    return raw
  }
}

/**
 * Folds a heading that has been clicked, or opens the way to a link's target.
 *
 * One listener on the document, so it survives every render — the elements it
 * acts on do not. Clicking the heading itself rather than only its marker is
 * the larger target and the one people try first; the marker is there to say
 * that the target exists.
 *
 * @param {MouseEvent} event - The click.
 */
function onClick(event) {
  // A link is never a fold, even inside a heading. An in-page one is answered
  // here first: WebKit scrolls it itself, but it cannot scroll to something
  // that is not on the page, and this runs before the navigation.
  const link = event.target.closest('a')
  if (link) {
    const target = link.hash && document.getElementById(fragmentOf(link))
    if (target) outline.reveal(target)
    return
  }

  const heading = event.target.closest('h1, h2, h3, h4, h5, h6')
  if (!heading || heading.parentElement !== doc() || !heading.id) return
  // A drag that selected the heading's text ends in a click too, and folding
  // the section out from under a selection is never what was meant.
  if (!window.getSelection().isCollapsed) return
  if (heading.classList.contains('bare')) return

  outline.toggle(heading, event.altKey)
}

doc().addEventListener('click', onClick)

/** The surface the Swift side drives. Nothing else is exported. */
window.Context = {
  /**
   * Renders Markdown into the page, replacing whatever was there.
   *
   * @param {string} b64 - Base64-encoded UTF-8 Markdown. Swift encodes it so no
   *   escaping games are needed to get it across the JS bridge.
   * @param {boolean} [keepScroll] - Hold the reading position. True for a
   *   re-render of the document already on screen, where an edit or a reload
   *   from the watcher must not move you; false for a different document, which
   *   starts at the top rather than at whatever offset the last one was left at.
   *
   * An empty document puts the body in the `empty` state, which reveals the
   * placeholder.
   */
  renderBase64(b64, keepScroll) {
    const src = decodeBase64Utf8(b64)

    const scroll = keepScroll ? document.documentElement.scrollTop : 0

    const el = doc()
    el.innerHTML = md.render(src)
    wrapTables(el)
    addHeadingIds(el)
    localizeURLs(el)
    // Folds belong to the document that was open: keep them across a re-render
    // of the same file — a save, or a reload from the watcher — and drop them
    // when a different one arrives, on the same test the scroll position uses.
    if (!keepScroll) outline.reset()
    outline.apply(el)
    document.body.classList.toggle('empty', src.trim() === '')
    // After the empty state, not before: an empty document hides #doc, and
    // nothing inside something display:none can be measured.
    markScrollers(el)

    document.documentElement.scrollTop = scroll
  },

  /**
   * Scrolls to an element by id, for a link that arrived from another file.
   *
   * WebKit does this itself for a link within the page, but a cross-file link is
   * not a navigation at all — the document is replaced under the same URL — so
   * the fragment has to be spent by hand once the new text is on screen.
   *
   * @param {string} b64 - Base64-encoded UTF-8 fragment, without the '#'.
   * @returns {boolean} Whether anything carried that id.
   */
  scrollToAnchor(b64) {
    const target = document.getElementById(decodeBase64Utf8(b64))
    if (!target) return false
    // A link from another file can land inside a folded section — the fold
    // belongs to the reader, but not so far as to swallow where they asked to go.
    outline.reveal(target)
    // block:'start' honours scroll-margin-top, so this lands with the same air
    // above it as WebKit's own scroll for an in-page link.
    target.scrollIntoView({ block: 'start', behavior: 'auto' })
    return true
  },

  /**
   * Searches the document and scrolls the first match into view.
   *
   * @param {string} b64 - Base64-encoded UTF-8 query, for the same reason the
   *   Markdown is: no escaping games to get it across the bridge. Empty clears
   *   the search.
   * @returns {{count: number, index: number}} Total matches and the 1-based
   *   position of the current one, 0 when there is none.
   */
  find(b64) {
    return finder.search(doc(), decodeBase64Utf8(b64))
  },

  /** @returns {{count: number, index: number}} After moving to the next match. */
  findNext() {
    return finder.step(1)
  },

  /** @returns {{count: number, index: number}} After moving to the previous one. */
  findPrevious() {
    return finder.step(-1)
  },

  /**
   * Rebuilds the match list against the document as it now stands.
   *
   * Called after a re-render, whose new nodes the old ranges know nothing about.
   *
   * @returns {{count: number, index: number}} The refreshed counts.
   */
  findRefresh() {
    return finder.refresh()
  },

  /** @returns {{count: number, index: number}} Zeroes; every highlight is gone. */
  findClear() {
    return finder.reset()
  },
}
