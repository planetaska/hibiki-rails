// hibiki-rails/motion — enter/leave motion for server-rendered swaps.
//
// Opt-in: `import "hibiki-rails/motion"` once, beside the controllers. This
// is the PUBLIC motion contract (unlike the client's private data-hibiki-*):
//
//   app-written    data-motion          the element animates its leave
//                  data-motion="own"    …only when the gesture that removed
//                                       it came from inside it — a destroyed
//                                       row, not one that paged or filtered
//                                       away. Marked elements need an id: both
//                                       sets below are keyed by id, as the
//                                       transports' swaps are.
//   written here   data-motion-leaving  on a marked element the incoming
//                                       render lacks, until its transitions end
//                  data-motion-entering on a marked element the render inserted,
//                                       until its first transitions end
//
// Addressed to app CSS — Tailwind's `starting:` / `data-motion-leaving:` /
// `in-data-motion-leaving:` variants, or plain attribute selectors. The
// enter needs no help: @starting-style is the from-state on a real
// insertion. The exit does, because a morph drops the node before any CSS
// could run — so a render that would remove a marked element is HELD until
// the element's transitions finish. Renders queue in arrival order, one
// chain per document, so a hold never lets a later render overtake it. Only
// the outermost marked element of a subtree moves, in either phase.
//
// One requestAnimationFrame per wait, because transitions exist only after
// the next style pass. A hidden document waits for nothing (its frames never
// come), and every wait races a one-second ceiling, so a tab hidden mid-hold
// cannot wedge the queue. Nothing here reads layout: a forced style read
// between a morph's insert and its class sync defeats @starting-style.
import { islandFor } from "hibiki-rails"

const CEILING = 1000

// Turbo stream actions that remove content. morph rides replace/update;
// append/prepend/before/after/refresh remove nothing.
const REMOVING = new Set(["replace", "update", "remove"])

const marked = (root) => [...root.querySelectorAll("[data-motion]")]
const hasMarks = (root) => root.querySelector("[data-motion]") !== null
const idsOf = (root) => new Set(marked(root).map((element) => element.id))

// `own`: the island's trip records are the honest gesture signal — the
// control of an in-flight trip, or the last control the island tracked
// (kept past its trip's settle; a render can land after the ack's grace).
const ownsGesture = (island, element) => {
  if (!island) return false
  for (const record of island.busy.values()) {
    if (record.control && element.contains(record.control)) return true
  }
  return Boolean(island.lastControl) && element.contains(island.lastControl)
}

const animates = (element, island) =>
  element.getAttribute("data-motion") !== "own" || ownsGesture(island, element)

// Marked elements under `target` (and `target` itself when the action
// replaces it) whose id the incoming content lacks.
const leavingFrom = (target, includeSelf, incoming, island) => {
  const candidates =
    includeSelf && target.hasAttribute("data-motion") ? [target, ...marked(target)] : marked(target)
  return candidates.filter(
    (element) => element.id && !incoming.has(element.id) && animates(element, island)
  )
}

const outermost = (elements) =>
  elements.filter((element) => !elements.some((other) => other !== element && other.contains(element)))

// Resolves once the element's own transitions have run. Element-only, not
// {subtree: true}: a spinner inside a leaving row is an infinite animation.
const settled = async (element) => {
  if (document.visibilityState === "hidden") return
  await new Promise(requestAnimationFrame)
  await Promise.allSettled((element.getAnimations?.() ?? []).map((animation) => animation.finished))
}

const finished = (elements) => {
  let timer
  const ceiling = new Promise((resolve) => {
    timer = setTimeout(resolve, CEILING)
  })
  return Promise.race([Promise.all(elements.map(settled)), ceiling]).finally(() => clearTimeout(timer))
}

// One chain per document. A failed render must not close it.
let queue = Promise.resolve()
const enqueue = (job) => (queue = queue.catch(() => {}).then(job))

// The hold. `plan` runs when the render's turn comes (earlier renders may
// have changed the DOM) and returns { leaving, islands }; `render` is what
// the transport would have run at once.
const held = (plan, render) =>
  enqueue(async () => {
    const { leaving: candidates, islands } = plan()
    const leaving = outermost(candidates)
    const before = idsOf(document)
    for (const element of leaving) element.setAttribute("data-motion-leaving", "")
    if (leaving.length) await finished(leaving)
    try {
      await render()
    } finally {
      // A render that kept the element after all, and the gesture consumed.
      for (const element of leaving) {
        if (element.isConnected) element.removeAttribute("data-motion-leaving")
      }
      for (const island of islands) island.lastControl = null
    }
    const entering = outermost(marked(document).filter((element) => element.id && !before.has(element.id)))
    for (const element of entering) {
      element.setAttribute("data-motion-entering", "")
      finished([element]).then(() => element.removeAttribute("data-motion-entering"))
    }
  })

// Turbo streams. Registered at import, so this wrapper sits INSIDE the
// islands' own render wrappers (theirs count the paint) and the hold ends
// before they count it. The gate keeps unmarked pages at two querySelectors;
// a hold is pending only while a marked element is still in the document,
// so any render arriving during one sees marks and queues behind it.
document.addEventListener("turbo:before-stream-render", (event) => {
  const stream = event.detail.newStream
  if (!stream?.templateElement) return
  const content = stream.templateElement.content
  if (!hasMarks(document) && !hasMarks(content)) return

  const render = event.detail.render
  event.detail.render = (streamElement) =>
    held(() => {
      const plan = { leaving: [], islands: new Set() }
      // A refresh stream has no target: targetElements throws.
      if (stream.action === "refresh") return plan
      const incoming = idsOf(content)
      for (const target of stream.targetElements) {
        const island = islandFor(target)
        if (island) plan.islands.add(island)
        if (REMOVING.has(stream.action)) {
          plan.leaving.push(...leavingFrom(target, stream.action !== "update", incoming, island))
        }
      }
      return plan
    }, () => render(streamElement))
})

// The transmit transport: the client's own swap, by root id. A root id
// always survives a by-id swap, so only descendants can leave.
document.addEventListener("hibiki:before-render", (event) => {
  const { island, content, render } = event.detail
  if (!hasMarks(document) && !hasMarks(content)) return

  event.detail.render = () =>
    held(() => ({
      islands: new Set([island]),
      leaving: [...content.children].flatMap((fragment) => {
        const target = document.getElementById(fragment.id)
        return target ? leavingFrom(target, false, idsOf(fragment), island) : []
      })
    }), render)
})
