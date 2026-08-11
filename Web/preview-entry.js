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
    document.body.classList.toggle('empty', src.trim() === '')

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
