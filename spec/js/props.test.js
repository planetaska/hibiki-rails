// DOM properties: state that has no HTML attribute (a checkbox's
// indeterminate, a container's scroll position) rides the fragment as
// data-hibiki-props and the client assigns it on connect and after each
// render.
import { beforeEach, afterEach, expect, it, vi } from "vitest"
import { island, mount, unmount, flush, receive } from "./support/island.js"

class FakeIntersectionObserver {
  constructor() { this.targets = new Set() }
  observe(target) { this.targets.add(target) }
  unobserve(target) { this.targets.delete(target) }
  disconnect() { this.targets.clear() }
}

let observers

beforeEach(() => {
  observers = []
  vi.useFakeTimers()
  vi.stubGlobal("IntersectionObserver", class extends FakeIntersectionObserver {
    constructor() { super(); observers.push(this) }
  })
})

afterEach(async () => {
  await unmount()
  vi.unstubAllGlobals()
  vi.useRealTimers()
})

const box = (props, id = "all") =>
  `<input type="checkbox" id="${id}" data-hibiki-props='${JSON.stringify(props)}'>`
const pane = (props) =>
  `<div id="pane" data-hibiki-props='${JSON.stringify(props)}'></div>`

// Turbo hands listeners a `render` it will await; the client wraps it.
const streamRender = async (render = () => {}) => {
  const event = new CustomEvent("turbo:before-stream-render", {
    bubbles: true,
    detail: { render }
  })
  document.dispatchEvent(event)
  await event.detail.render()
  await flush()
}

it("applies a property on connect, before the subscription confirms", async () => {
  const root = await mount(island(box({ indeterminate: true })), { autoConnect: false })
  expect(root.dataset.hibikiState).toBe("connecting")
  expect(root.querySelector("#all").indeterminate).toBe(true)
})

it("applies the replacement's property after hibiki swaps the fragment", async () => {
  await mount(island(`<div id="bar">${box({ indeterminate: false })}</div>`))
  expect(document.querySelector("#all").indeterminate).toBe(false)

  await receive({ html: `<div id="bar">${box({ indeterminate: true })}</div>` })
  expect(document.querySelector("#all").indeterminate).toBe(true)
})

// A morph keeps the element and rewrites its attribute.
it("applies a morphed attribute after a Turbo stream render", async () => {
  const root = await mount(island(box({ indeterminate: true })))
  const all = root.querySelector("#all")

  await streamRender(() => all.setAttribute("data-hibiki-props", '{"indeterminate":false}'))
  expect(all.indeterminate).toBe(false)
})

// The browser clears indeterminate on click; the server's value wins again
// with the next render even though the attribute never changed.
it("re-applies indeterminate on every render", async () => {
  const root = await mount(island(box({ indeterminate: true })))
  const all = root.querySelector("#all")
  all.indeterminate = false

  await streamRender()
  expect(all.indeterminate).toBe(true)
})

it("applies a scroll position once and leaves the visitor's scrolling alone", async () => {
  const root = await mount(island(pane({ scrollTop: 40 })))
  const el = root.querySelector("#pane")
  expect(el.scrollTop).toBe(40)

  el.scrollTop = 300
  await streamRender()
  expect(el.scrollTop).toBe(300)
})

it("applies a scroll position again when its value changes", async () => {
  const root = await mount(island(pane({ scrollTop: 40 })))
  const el = root.querySelector("#pane")
  el.scrollTop = 300

  await streamRender(() => el.setAttribute("data-hibiki-props", '{"scrollTop":0}'))
  expect(el.scrollTop).toBe(0)
})

// key: is how a view says "again" when the value itself never changes.
it("applies a scroll position again when only the key changes", async () => {
  const root = await mount(island(pane({ scrollTop: 0, key: "jazz" })))
  const el = root.querySelector("#pane")
  el.scrollTop = 300

  await streamRender(() => el.setAttribute("data-hibiki-props", '{"scrollTop":0,"key":"rock"}'))
  expect(el.scrollTop).toBe(0)
})

it("applies a scroll position to a replacement element", async () => {
  await mount(island(`<div id="wrap">${pane({ scrollLeft: 25 })}</div>`))
  await receive({ html: `<div id="wrap">${pane({ scrollLeft: 25 })}</div>` })
  expect(document.querySelector("#pane").scrollLeft).toBe(25)
})

it("ignores a property outside the allowlist", async () => {
  const root = await mount(island(
    `<div id="pane" data-hibiki-props='{"innerHTML":"<b>x</b>","title":"t","scrollTop":7}'>kept</div>`
  ))
  const el = root.querySelector("#pane")
  expect(el.innerHTML).toBe("kept")
  expect(el.title).toBe("")
  expect(el.scrollTop).toBe(7)
})

it("ignores a value of the wrong type", async () => {
  const root = await mount(island(
    box({ indeterminate: "yes" }) + pane({ scrollTop: "40" })
  ))
  expect(root.querySelector("#all").indeterminate).toBe(false)
  expect(root.querySelector("#pane").scrollTop).toBe(0)
})

// Malformed JSON on one element must not stop the scan: the sentinel
// after it still has to be observed.
it("skips an element whose attribute does not parse", async () => {
  const root = await mount(island(
    `<input type="checkbox" id="bad" data-hibiki-props="{nope">
     ${box({ indeterminate: true })}
     <button id="more" data-hibiki-on="visible->load_more"></button>`
  ))
  expect(root.querySelector("#all").indeterminate).toBe(true)
  expect([...observers.at(-1).targets]).toEqual([root.querySelector("#more")])
})

// A refresh stream morphs the page after the stream's own render has
// returned, so turbo:render is the only seam that sees it.
it("rescans after a Turbo page render", async () => {
  const root = await mount(island(box({ indeterminate: true })))
  const all = root.querySelector("#all")
  all.setAttribute("data-hibiki-props", '{"indeterminate":false}')
  root.insertAdjacentHTML("beforeend", `<button id="more" data-hibiki-on="visible->load_more"></button>`)

  document.dispatchEvent(new CustomEvent("turbo:render", { bubbles: true }))
  await flush()

  expect(all.indeterminate).toBe(false)
  expect([...observers.at(-1).targets]).toEqual([root.querySelector("#more")])
})

it("stops rescanning when the island disconnects", async () => {
  const root = await mount(island(box({ indeterminate: true })))
  const all = root.querySelector("#all")
  await unmount()
  all.indeterminate = false
  document.dispatchEvent(new CustomEvent("turbo:render", { bubbles: true }))
  expect(all.indeterminate).toBe(false)
})
