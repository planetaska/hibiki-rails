// The { url } message (transmit_url): mirror graph state into the address
// bar. replaceState, never pushState — the URL is a mirror, not a history
// entry — and same-origin only, so a channel can move the bar solely
// within its own app.
import { beforeEach, afterEach, describe, expect, it, vi } from "vitest"
import { island, mount, unmount, receive } from "./support/island.js"

beforeEach(() => vi.useFakeTimers())
afterEach(async () => {
  await unmount()
  vi.useRealTimers()
})

describe("the url message", () => {
  it("replaces the bar with a same-origin path", async () => {
    await mount(island(""))
    await receive({ url: "/songs?page=2" })

    expect(window.location.pathname).toBe("/songs")
    expect(window.location.search).toBe("?page=2")
  })

  it("replaces rather than pushes — no new history entry", async () => {
    await mount(island(""))
    const length = window.history.length
    await receive({ url: "/songs?page=2" })
    await receive({ url: "/songs?page=3" })

    expect(window.history.length).toBe(length)
  })

  it("refuses a cross-origin URL", async () => {
    await mount(island(""))
    const before = window.location.href
    await receive({ url: "https://evil.example/phish" })

    expect(window.location.href).toBe(before)
  })

  it("takes an absolute same-origin URL", async () => {
    await mount(island(""))
    await receive({ url: `${window.location.origin}/songs/7/edit` })

    expect(window.location.pathname).toBe("/songs/7/edit")
  })
})
