// Find for the reading pane. Bundled into preview.js along with the rest of Web/.
//
// Matches are kept as DOM Ranges and painted with the CSS Custom Highlight API,
// so nothing in the document is wrapped, moved or restyled to show them: the
// grid layout, the KaTeX boxes and the highlight.js token spans stay exactly as
// they were rendered.

import * as outline from './outline.js'

/**
 * Elements whose text is in the DOM but never on the page.
 *
 * KaTeX emits every formula twice — the visible HTML and a MathML copy clipped
 * to a 1px box for accessibility — so an unfiltered walk also finds each
 * equation's TeX source and scrolls to a match nobody can see.
 */
const SKIP = '.katex-mathml, script, style'

/**
 * Elements that end a run of text.
 *
 * Text nodes are concatenated so a match can cross inline markup — searching
 * 'hello world' finds `hello *world*` — but it must not cross a block boundary,
 * or two adjacent paragraphs would join into a word that is nowhere on the page.
 */
const BLOCK = [
  'p', 'div', 'li', 'td', 'th', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'pre',
  'blockquote', 'section', 'ul', 'ol', 'table', 'dl', 'dt', 'dd', 'figure',
  'figcaption',
].join(', ')

/** The live search: every match as a Range, and which one is current. */
const state = {
  root: null,
  query: '',
  ranges: [],
  index: -1,
}

/**
 * Escapes a literal so it can be used as a regular expression.
 *
 * @param {string} text - Any string.
 * @returns {string} The same string with every character that means something
 *   in a pattern backslashed.
 */
function escapeForRegExp(text) {
  return text.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
}

/**
 * Folds text to what a reader would type, so a search matches what it looks
 * like rather than what it is made of.
 *
 * Three things get between the two. markdown-it's typographer turns quotes
 * curly and `--` into a dash, and nobody searching for "don't" types the
 * apostrophe as U+2019. Markdown source is hard-wrapped, and those line breaks
 * survive into the text node, so a phrase crossing one holds a newline where the
 * reader sees a space. And KaTeX sets `\text{a b}` with a non-breaking space,
 * as does any `&nbsp;` in the source.
 *
 * Every substitution is one character for one — that is what lets an offset
 * into the folded text index the original.
 *
 * @param {string} text - Any string.
 * @returns {string} The same length, with ASCII punctuation and plain spaces.
 */
function fold(text) {
  return text
    .replace(/[‘’‛]/g, "'")
    .replace(/[“”]/g, '"')
    .replace(/[–—]/g, '-')
    // JavaScript's \s already covers the non-breaking and typographic spaces,
    // and matches one character at a time, so the length is preserved.
    .replace(/\s/g, ' ')
}

/**
 * Flattens the rendered document into one searchable string.
 *
 * @param {HTMLElement} root - The rendered document.
 * @returns {{text: string, spans: Array<{node: Text, start: number}>}} The text
 *   as it reads on the page, and where in it each text node begins. `spans` is
 *   ordered by `start`, which is what `spanAt` relies on.
 */
function buildIndex(root) {
  const spans = []
  let text = ''
  let block = null

  const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
    acceptNode(node) {
      if (!node.nodeValue || !node.parentElement) return NodeFilter.FILTER_REJECT
      return node.parentElement.closest(SKIP)
        ? NodeFilter.FILTER_REJECT
        : NodeFilter.FILTER_ACCEPT
    },
  })

  for (let node = walker.nextNode(); node; node = walker.nextNode()) {
    const owner = node.parentElement.closest(BLOCK)
    // A newline between blocks, added after folding so it is the one newline the
    // text can hold. A query is folded too, and so can never contain one — that
    // is what stops a match spanning two blocks.
    if (text && owner !== block) text += '\n'
    block = owner
    spans.push({ node, start: text.length })
    text += fold(node.nodeValue)
  }

  return { text, spans }
}

/**
 * Locates the text node covering an offset into the flattened text.
 *
 * @param {Array<{node: Text, start: number}>} spans - Ordered by `start`.
 * @param {number} offset - An offset inside a text node, never one of the
 *   newlines `buildIndex` puts between blocks.
 * @returns {{node: Text, start: number}} The span it falls in.
 */
function spanAt(spans, offset) {
  let low = 0
  let high = spans.length - 1
  while (low < high) {
    const mid = (low + high + 1) >> 1
    if (spans[mid].start <= offset) low = mid
    else high = mid - 1
  }
  return spans[low]
}

/**
 * Turns a region of the flattened text back into a DOM range.
 *
 * @param {Array<{node: Text, start: number}>} spans - From `buildIndex`.
 * @param {number} start - Inclusive offset.
 * @param {number} end - Exclusive offset, greater than `start`.
 * @returns {Range} A range over the original nodes, spanning several of them
 *   when the match crossed inline markup.
 */
function rangeFor(spans, start, end) {
  const first = spanAt(spans, start)
  const last = spanAt(spans, end - 1)
  const range = document.createRange()
  range.setStart(first.node, start - first.start)
  range.setEnd(last.node, end - last.start)
  return range
}

/**
 * Finds every occurrence of a query in the document.
 *
 * @param {HTMLElement} root - The rendered document.
 * @param {string} query - Plain, non-empty text. Matched case-insensitively;
 *   an escaped literal can never match nothing, which is what bounds the loop.
 * @returns {Range[]} One range per match, in document order.
 */
function collect(root, query) {
  const { text, spans } = buildIndex(root)
  if (!spans.length) return []

  const pattern = new RegExp(escapeForRegExp(fold(query)), 'giu')
  const ranges = []
  for (let match = pattern.exec(text); match; match = pattern.exec(text)) {
    ranges.push(rangeFor(spans, match.index, match.index + match[0].length))
  }
  return ranges
}

/**
 * Paints the current matches.
 *
 * The CSS Custom Highlight API styles ranges without touching the DOM. Where it
 * is missing (WebKit before Safari 17.2) the document selection stands in for
 * the current match, so find still shows you where you are — just without the
 * other hits lit up behind it.
 */
function paint() {
  if (!window.CSS || !CSS.highlights || typeof Highlight === 'undefined') {
    const selection = window.getSelection()
    selection.removeAllRanges()
    if (state.index >= 0) selection.addRange(state.ranges[state.index])
    return
  }

  CSS.highlights.delete('find')
  CSS.highlights.delete('find-current')
  if (!state.ranges.length) return

  CSS.highlights.set('find', new Highlight(...state.ranges))
  if (state.index >= 0) {
    const current = new Highlight(state.ranges[state.index])
    // Both highlights cover the current match; priority decides which paints.
    current.priority = 1
    CSS.highlights.set('find-current', current)
  }
}

/**
 * Scrolls the current match to the middle of the window.
 *
 * A Range has no `scrollIntoView`, so this works from its own rectangle. The
 * jump is instant: find is a rapid back-and-forth, and an animation reads as the
 * app lagging behind the key.
 */
function reveal() {
  if (state.index < 0) return
  // A fold hides the page, not the document: a match can be found inside a
  // folded section, and showing it means opening the way in first.
  outline.reveal(state.ranges[state.index].startContainer)
  const rect = state.ranges[state.index].getBoundingClientRect()
  const top = window.scrollY + rect.top - (window.innerHeight - rect.height) / 2
  window.scrollTo({ top: Math.max(0, top), behavior: 'auto' })
}

/**
 * @returns {{count: number, index: number}} Total matches, and the 1-based
 *   position of the current one — 0 when there is none. This is what the find
 *   bar reads back across the bridge.
 */
function status() {
  return { count: state.ranges.length, index: state.index + 1 }
}

/**
 * Runs a search, making current the first match at or below the top of the
 * window.
 *
 * Starting from what is on screen rather than from the top of the document is
 * what makes ⌘F pick up where you are reading.
 *
 * @param {HTMLElement} root - The rendered document.
 * @param {string} query - Plain text. Empty clears the search.
 * @returns {{count: number, index: number}} See `status`.
 */
export function search(root, query) {
  state.root = root
  state.query = query
  state.ranges = query ? collect(root, query) : []

  const onScreen = state.ranges.findIndex((range) => range.getBoundingClientRect().top >= 0)
  state.index = state.ranges.length ? Math.max(onScreen, 0) : -1

  paint()
  reveal()
  return status()
}

/**
 * Moves to another match, wrapping at either end.
 *
 * @param {number} delta - +1 for the next match, -1 for the previous.
 * @returns {{count: number, index: number}} See `status`.
 */
export function step(delta) {
  const total = state.ranges.length
  if (!total) return status()
  state.index = (state.index + delta + total) % total
  paint()
  reveal()
  return status()
}

/**
 * Re-runs the current search after the document has been rendered again.
 *
 * Ranges point at text nodes that stop existing the moment the document is
 * replaced, so they have to be rebuilt. The match number is kept where it still
 * exists and the page is not scrolled: a reload from the file watcher should
 * leave you where you were.
 *
 * @returns {{count: number, index: number}} See `status`.
 */
export function refresh() {
  if (!state.root || !state.query) return status()
  const previous = state.index
  state.ranges = collect(state.root, state.query)
  state.index = state.ranges.length
    ? Math.min(Math.max(previous, 0), state.ranges.length - 1)
    : -1
  paint()
  return status()
}

/**
 * Ends the search and drops every highlight.
 *
 * @returns {{count: number, index: number}} See `status` — always zeroes.
 */
export function reset() {
  state.query = ''
  state.ranges = []
  state.index = -1
  paint()
  return status()
}
