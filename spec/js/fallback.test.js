// The fallback contract: a control stamped data-hibiki-fallback declares
// its native behavior (a link's navigation, a form's own action=) as the
// degraded path. Only a `ready` island intercepts the event and performs
// the channel action; in every other state the client stands aside — no
// preventDefault, no perform, no queueing — and the browser does what the
// markup says.
import { beforeEach, afterEach, describe, expect, it, vi } from "vitest"
import {
  island, mount, unmount, performed, sent, cable, connectAll, disconnectAll
} from "./support/island.js"

beforeEach(() => vi.useFakeTimers())
afterEach(async () => {
  await unmount()
  vi.useRealTimers()
  vi.restoreAllMocks()
})

const CEILING = 10000

const link =
  `<a href="/songs/new" data-hibiki-on="click->new_form" data-hibiki-fallback="true">New</a>`

const click = (control) => {
  const event = new MouseEvent("click", { bubbles: true, cancelable: true })
  control.dispatchEvent(event)
  return event
}

describe("a ready island", () => {
  it("intercepts the event and performs only the action", async () => {
    const root = await mount(island(link))
    const event = click(root.querySelector("a"))

    expect(event.defaultPrevented).toBe(true)
    expect(performed).toEqual([["new_form", {}]])
  })

  it("still never prevents a control without the flag", async () => {
    const root = await mount(
      island(`<a href="/songs/new" data-hibiki-on="click->new_form">New</a>`)
    )
    const event = click(root.querySelector("a"))

    expect(event.defaultPrevented).toBe(false)
    expect(performed).toEqual([["new_form", {}]])
  })

  it("keeps a declined confirm on the page — prevented, nothing performed", async () => {
    vi.stubGlobal("confirm", () => false)
    const root = await mount(
      island(link.replace(">New", ` data-hibiki-confirm="Sure?">New`))
    )
    const event = click(root.querySelector("a"))

    expect(event.defaultPrevented).toBe(true)
    expect(performed).toEqual([])
    vi.unstubAllGlobals()
  })
})

describe("standing aside", () => {
  // Deliberately not the connect-window queue: a queued gesture renders
  // nothing until the link comes up, while the href answers immediately.
  it("lets the connect window navigate natively, and never replays it", async () => {
    const root = await mount(island(link), { autoConnect: false })
    const event = click(root.querySelector("a"))

    expect(event.defaultPrevented).toBe(false)
    expect(performed).toEqual([])

    await connectAll()
    expect(sent).toEqual([])
  })

  it("lets an offline island navigate natively", async () => {
    const root = await mount(island(link))
    await disconnectAll()
    const event = click(root.querySelector("a"))

    expect(event.defaultPrevented).toBe(false)
    expect(performed).toEqual([])
  })

  it("lets a stalled island navigate natively — the escape hatch", async () => {
    const root = await mount(island(link))
    click(root.querySelector("a"))
    await vi.advanceTimersByTimeAsync(CEILING)
    expect(root.getAttribute("data-hibiki-state")).toBe("stalled")

    const event = click(root.querySelector("a"))
    expect(event.defaultPrevented).toBe(false)
    expect(performed).toEqual([["new_form", {}]])
  })

  it("lets a form submit to its own action= when not ready", async () => {
    const root = await mount(
      island(
        `<form action="/songs" method="post" data-hibiki-on="submit->create"
               data-hibiki-fallback="true"><input name="title" value="x"></form>`
      ),
      { autoConnect: false }
    )
    const event = new Event("submit", { bubbles: true, cancelable: true })
    root.querySelector("form").dispatchEvent(event)

    expect(event.defaultPrevented).toBe(false)
    expect(performed).toEqual([])
  })

  // Scripts are running, so a destructive native submit must not slip
  // past the dialog just because the island is down.
  it("still confirms before standing aside — declined stays put", async () => {
    vi.stubGlobal("confirm", () => false)
    const root = await mount(
      island(link.replace(">New", ` data-hibiki-confirm="Sure?">New`)),
      { autoConnect: false }
    )
    const event = click(root.querySelector("a"))

    expect(event.defaultPrevented).toBe(true)
    expect(performed).toEqual([])
    vi.unstubAllGlobals()
  })

  it("lets an accepted confirm proceed natively", async () => {
    vi.stubGlobal("confirm", () => true)
    const root = await mount(
      island(link.replace(">New", ` data-hibiki-confirm="Sure?">New`)),
      { autoConnect: false }
    )
    const event = click(root.querySelector("a"))

    expect(event.defaultPrevented).toBe(false)
    expect(performed).toEqual([])
    vi.unstubAllGlobals()
  })
})

// A channel-rendered repaint has no session, so the form it painted embeds
// a stale authenticity_token or none at all. The page's csrf-token meta is
// first-paint fresh — and these paths only run with scripts alive, which
// is exactly when the DOM may have been repainted.
describe("the csrf token of a fallback form going native", () => {
  const meta = (content) => {
    const tag = document.createElement("meta")
    tag.name = "csrf-token"
    tag.content = content
    document.head.appendChild(tag)
    return tag
  }
  afterEach(() => document.querySelector('meta[name="csrf-token"]')?.remove())

  const form =
    `<form action="/songs/1" method="post" data-hibiki-on="submit->destroy"
           data-hibiki-fallback="true"><input type="hidden" name="_method" value="delete"></form>`

  it("injects the meta token into a tokenless form on stand-aside", async () => {
    meta("fresh-token")
    const root = await mount(island(form), { autoConnect: false })
    root.querySelector("form").dispatchEvent(
      new Event("submit", { bubbles: true, cancelable: true })
    )

    const input = root.querySelector('input[name="authenticity_token"]')
    expect(input?.value).toBe("fresh-token")
  })

  it("overwrites a stale embedded token on stand-aside", async () => {
    meta("fresh-token")
    const root = await mount(
      island(form.replace("</form>",
        `<input type="hidden" name="authenticity_token" value="stale"></form>`)),
      { autoConnect: false }
    )
    root.querySelector("form").dispatchEvent(
      new Event("submit", { bubbles: true, cancelable: true })
    )

    expect(root.querySelector('input[name="authenticity_token"]').value).toBe("fresh-token")
  })

  it("freshens before the dead-socket fallthrough submits", async () => {
    meta("fresh-token")
    let tokenAtSubmit
    vi.spyOn(window.HTMLFormElement.prototype, "submit").mockImplementation(function () {
      tokenAtSubmit = this.querySelector('input[name="authenticity_token"]')?.value
    })
    const root = await mount(island(form))
    cable.sendResult = false
    root.querySelector("form").dispatchEvent(
      new Event("submit", { bubbles: true, cancelable: true })
    )

    expect(tokenAtSubmit).toBe("fresh-token")
  })

  it("touches nothing without the meta tag", async () => {
    const root = await mount(island(form), { autoConnect: false })
    root.querySelector("form").dispatchEvent(
      new Event("submit", { bubbles: true, cancelable: true })
    )

    expect(root.querySelector('input[name="authenticity_token"]')).toBeNull()
  })
})

// The socket died but the connection monitor has not noticed: `subscribed`
// still says live, dispatch prevents the default, and Subscription#perform
// returns false. The frame went nowhere, so navigating cannot double-fire
// the action.
describe("the dead-but-undetected socket", () => {
  it("navigates the fallback by hand and marks the island offline", async () => {
    const assign = vi.fn()
    const root = await mount(island(link))
    vi.spyOn(window.location, "assign").mockImplementation(assign)
    cable.sendResult = false

    const event = click(root.querySelector("a"))

    expect(event.defaultPrevented).toBe(true)
    expect(assign).toHaveBeenCalledOnce()
    expect(assign.mock.calls[0][0]).toMatch(/\/songs\/new$/)
    expect(root.getAttribute("data-hibiki-state")).toBe("offline")
    // The trip settled at once — nothing left to stall out at the ceiling.
    await vi.advanceTimersByTimeAsync(CEILING)
    expect(root.getAttribute("data-hibiki-state")).toBe("offline")
    expect(root.hasAttribute("data-hibiki-busy")).toBe(false)
  })

  it("submits a fallback form to its own action= by hand", async () => {
    const submit = vi
      .spyOn(window.HTMLFormElement.prototype, "submit")
      .mockImplementation(() => {})
    const root = await mount(
      island(
        `<form action="/songs" method="post" data-hibiki-on="submit->create"
               data-hibiki-fallback="true"><input name="title" value="x"></form>`
      )
    )
    cable.sendResult = false

    const event = new Event("submit", { bubbles: true, cancelable: true })
    root.querySelector("form").dispatchEvent(event)

    expect(event.defaultPrevented).toBe(true)
    expect(submit).toHaveBeenCalledOnce()
  })

  it("recovers to ready when the monitor reconnects", async () => {
    const root = await mount(island(link))
    vi.spyOn(window.location, "assign").mockImplementation(() => {})
    cable.sendResult = false
    click(root.querySelector("a"))
    expect(root.getAttribute("data-hibiki-state")).toBe("offline")

    cable.sendResult = true
    await connectAll()
    expect(root.getAttribute("data-hibiki-state")).toBe("ready")

    const event = click(root.querySelector("a"))
    expect(event.defaultPrevented).toBe(true)
    expect(performed).toEqual([["new_form", {}], ["new_form", {}]])
  })
})
