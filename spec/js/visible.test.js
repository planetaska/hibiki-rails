// The `visible` pseudo-event: an IntersectionObserver sentinel, so one
// element can answer both a click and "scrolled into view".
//
// happy-dom has no layout, so it has no real IntersectionObserver. The stub
// below records what is being observed and lets an example say "this one is
// on screen now" — which is exactly the contract the client depends on.
import { beforeEach, afterEach, describe, expect, it, vi } from "vitest"
import { island, mount, unmount, performed, flush, subscriptions } from "./support/island.js"

const observers = []

class FakeIntersectionObserver {
  constructor(callback) {
    this.callback = callback
    this.targets = new Set()
    observers.push(this)
  }

  observe(target) {
    this.targets.add(target)
  }

  unobserve(target) {
    this.targets.delete(target)
  }

  disconnect() {
    this.targets.clear()
  }

  // Test-only: report the given elements as on screen. Only elements
  // currently under observation get an entry — a real observer stops
  // delivering the moment unobserve() is called, and that is precisely the
  // brake these examples are checking for.
  scrollIntoView(...targets) {
    const entries = targets
      .filter((target) => this.targets.has(target))
      .map((target) => ({ target, isIntersecting: true }))
    if (entries.length) this.callback(entries)
  }
}

const observer = () => observers.at(-1)

beforeEach(() => {
  observers.length = 0
  vi.useFakeTimers()
  vi.stubGlobal("IntersectionObserver", FakeIntersectionObserver)
})

afterEach(async () => {
  await unmount()
  vi.unstubAllGlobals()
  vi.useRealTimers()
})

const sentinel = `<button id="load_more"
  data-hibiki-on="click->load_more visible->load_more"
  data-hibiki-with='{"shown":20}'></button>`

it("observes every visible-> sentinel the island owns", async () => {
  const root = await mount(island(sentinel))
  expect([...observer().targets]).toEqual([root.querySelector("#load_more")])
})

it("does not observe controls without a visible token", async () => {
  await mount(island(`<button data-hibiki-on="click->increment"></button>`))
  expect(observer().targets.size).toBe(0)
})

it("performs the action when the sentinel comes into view", async () => {
  const root = await mount(island(sentinel))
  observer().scrollIntoView(root.querySelector("#load_more"))
  expect(performed).toEqual([["load_more", { shown: 20 }]])
})

it("still answers a plain click on the same element", async () => {
  const root = await mount(island(sentinel))
  root.querySelector("#load_more").click()
  expect(performed).toEqual([["load_more", { shown: 20 }]])
})

// The server-side generation token absorbs a genuine double-fire; this is
// the client's own brake, so a sentinel parked in the viewport does not
// perform on every observer callback.
it("fires once per observation", async () => {
  const root = await mount(island(sentinel))
  const control = root.querySelector("#load_more")
  observer().scrollIntoView(control)
  observer().scrollIntoView(control)
  expect(performed).toEqual([["load_more", { shown: 20 }]])
})

// The whole point of re-scanning: the replacement element gets a fresh
// initial callback, so a page that did not fill the viewport keeps paging
// instead of stalling.
it("re-observes the replacement after hibiki swaps the fragment", async () => {
  const root = await mount(island(`<div id="list">${sentinel}</div>`))
  observer().scrollIntoView(root.querySelector("#load_more"))
  expect(observer().targets.size).toBe(0)

  // The transmit transport's own swap point.
  subscriptions.at(-1).handlers.received({
    html: `<div id="list">${sentinel.replace('"shown":20', '"shown":40')}</div>`
  })
  await flush()

  expect(observer().targets.size).toBe(1)
  observer().scrollIntoView(document.querySelector("#load_more"))
  expect(performed).toEqual([
    ["load_more", { shown: 20 }],
    ["load_more", { shown: 40 }]
  ])
})

it("re-observes after a Turbo stream render", async () => {
  const root = await mount(island(`<div id="list">${sentinel}</div>`))
  observer().scrollIntoView(root.querySelector("#load_more"))
  expect(observer().targets.size).toBe(0)

  // Turbo hands listeners a `render` it will await; the client wraps it.
  const event = new CustomEvent("turbo:before-stream-render", {
    bubbles: true,
    detail: { render: () => {} }
  })
  document.dispatchEvent(event)
  await event.detail.render()
  await flush()

  expect(observer().targets.size).toBe(1)
})

it("stops observing when the island disconnects", async () => {
  await mount(island(sentinel))
  const live = observer()
  await unmount()
  expect(live.targets.size).toBe(0)
})
