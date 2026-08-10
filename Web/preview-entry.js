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

for (const [name, lang] of Object.entries({
  bash, c, cpp, css, diff, dockerfile, go, ini, java, javascript, json, julia,
  latex, lua, makefile, markdown, python, r, ruby, rust, scss, shell, sql,
  swift, typescript, xml, yaml,
})) {
  hljs.registerLanguage(name, lang)
}

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

// Tables can exceed the reading measure; the stylesheet gives the wrapper its
// own scroll context so the page itself never scrolls sideways.
function wrapTables(root) {
  for (const table of root.querySelectorAll(':scope > table')) {
    const wrap = document.createElement('div')
    wrap.className = 'table-scroll'
    table.replaceWith(wrap)
    wrap.appendChild(table)
  }
}

// Stable ids so in-document links and future outline work have something to
// aim at. Duplicate headings get a numeric suffix.
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

// Relative images and links are resolved by the Swift side against the
// document's own directory, via a custom scheme. Without this the webview —
// which is loaded out of the app bundle — has no way to reach them.
const ABSOLUTE = /^(?:[a-z][a-z0-9+.-]*:|\/\/|#)/i

function localizeURLs(root) {
  const rewrite = (el, attr) => {
    const raw = el.getAttribute(attr)
    if (!raw || ABSOLUTE.test(raw)) return
    const [path, hash] = raw.split('#')
    if (!path) return
    const host = path.startsWith('/') ? 'abs' : 'doc'
    const clean = path.replace(/^\.\//, '').replace(/^\//, '')
    el.setAttribute(attr, `context-doc://${host}/` + encodeURI(clean) + (hash ? '#' + hash : ''))
  }
  for (const img of root.querySelectorAll('img[src]')) rewrite(img, 'src')
  for (const a of root.querySelectorAll('a[href]')) rewrite(a, 'href')
}

const doc = () => document.getElementById('doc')

function decodeBase64Utf8(b64) {
  const bin = atob(b64)
  const bytes = new Uint8Array(bin.length)
  for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i)
  return new TextDecoder('utf-8').decode(bytes)
}

window.Context = {
  // Swift base64-encodes the source so no escaping games are needed to get it
  // across the JS bridge.
  renderBase64(b64) {
    const src = decodeBase64Utf8(b64)

    // A reload from a file-watch event should leave you where you were reading,
    // so hold the scroll offset across the swap.
    const scroll = document.documentElement.scrollTop

    const el = doc()
    el.innerHTML = md.render(src)
    wrapTables(el)
    addHeadingIds(el)
    localizeURLs(el)
    document.body.classList.toggle('empty', src.trim() === '')

    document.documentElement.scrollTop = scroll
  },

  scrollToTop() {
    document.documentElement.scrollTo({ top: 0, behavior: 'smooth' })
  },
}
