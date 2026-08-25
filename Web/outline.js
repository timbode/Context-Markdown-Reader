// Collapsible headings for the reading pane. Bundled into preview.js with the
// rest of Web/.
//
// A heading owns everything after it up to the next heading of its own level or
// higher, exactly as an outline reads. Folding hides that run with the `hidden`
// attribute rather than moving it, so nothing is taken out of the grid and put
// back — the document's layout is the same document, minus some rows.
//
// Which headings are folded is held here rather than in the DOM, because a
// render replaces every element in the page: `Document` reloading from the file
// watcher, or a keystroke in the editor, would otherwise unfold everything the
// reader had folded.

/** Heading tag to outline level. Anything absent is not a heading. */
const LEVEL = { H1: 1, H2: 2, H3: 3, H4: 4, H5: 5, H6: 6 }

/** Ids of the folded headings, for as long as the document stays the same. */
const folded = new Set()

/**
 * The outline level of an element, or 0 when it is not a heading.
 *
 * @param {Element} el - Any element.
 * @returns {number} 1 to 6, or 0.
 */
function levelOf(el) {
  return LEVEL[el.tagName] || 0
}

/**
 * Whether a heading has anything under it to fold.
 *
 * The last heading in a document, or one immediately followed by a heading of
 * its own level, owns nothing — and offers no marker, because clicking it could
 * only be a disappointment.
 *
 * @param {Element} heading - A heading element.
 * @returns {boolean} True when the fold would hide at least one element.
 */
function hasBody(heading) {
  const next = heading.nextElementSibling
  if (!next) return false
  const level = levelOf(next)
  return level === 0 || level > levelOf(heading)
}

/**
 * Hides or reveals every element to match the folded set.
 *
 * One pass over the document, carrying a stack of the levels doing the folding:
 * a heading pops everything at its level or deeper, so `## B` ends the fold that
 * `## A` began, and an element is hidden whenever the stack is not empty. A
 * heading folded *inside* another fold stays folded — reopening the outer one
 * shows it still closed, which is the state the reader left it in.
 *
 * @param {HTMLElement} root - The rendered document. Mutated in place.
 */
export function apply(root) {
  const stack = []
  for (const el of root.children) {
    const level = levelOf(el)
    while (level && stack.length && stack[stack.length - 1] >= level) stack.pop()

    el.hidden = stack.length > 0

    if (level) {
      const shut = folded.has(el.id)
      const body = hasBody(el)
      el.classList.toggle('folded', shut && body)
      el.classList.toggle('bare', !body)
      if (shut && body) stack.push(level)
    }
  }

  // What is on the page has changed without a render — anything measuring the
  // document (the scrollbar lanes) has to be told, and this keeps that from
  // being every caller's job.
  root.dispatchEvent(new CustomEvent('outlinechange'))
}

/**
 * Folds or unfolds one heading.
 *
 * @param {Element} heading - A heading that is a child of the document root.
 * @param {boolean} [everything] - Do the same to every heading in the document,
 *   which is what ⌥-click asks for: one gesture to collapse a long file to its
 *   outline, and one to open it again.
 */
export function toggle(heading, everything) {
  const root = heading.parentElement
  const shut = !folded.has(heading.id)

  if (everything) {
    folded.clear()
    if (shut) {
      for (const el of root.children) {
        if (levelOf(el) && el.id && hasBody(el)) folded.add(el.id)
      }
    }
  } else if (shut) {
    folded.add(heading.id)
  } else {
    folded.delete(heading.id)
  }

  apply(root)
}

/**
 * Opens whatever is hiding a node, so something can be shown at it.
 *
 * Find matches text it cannot see — a fold hides the page, not the document —
 * and a link may point into a folded section. Both have to open the way in
 * before they scroll, or they land on nothing.
 *
 * Walks back from the element towards the top of the document, taking only
 * headings shallower than the last one seen: that is the chain of headings the
 * node sits under, and the only ones whose fold could be hiding it.
 *
 * @param {Node} node - Any node in the document.
 * @returns {boolean} Whether anything was opened.
 */
export function reveal(node) {
  const el = node.nodeType === Node.ELEMENT_NODE ? node : node.parentElement
  const top = el?.closest('#doc > *')
  if (!top || !top.hidden) return false

  // A heading of its own is not opened by this: what hides it is the fold it
  // sits under, and the reader shut its own for a reason.
  let deepest = levelOf(top) || 7
  let opened = false
  for (let above = top.previousElementSibling; above; above = above.previousElementSibling) {
    const level = levelOf(above)
    if (!level || level >= deepest) continue
    deepest = level
    opened = folded.delete(above.id) || opened
    if (level === 1) break
  }

  if (opened) apply(top.parentElement)
  return opened
}

/**
 * Forgets every fold.
 *
 * Called when a different document is rendered: the ids belong to the file that
 * was open, and a slug from one document means nothing in the next.
 */
export function reset() {
  folded.clear()
}
