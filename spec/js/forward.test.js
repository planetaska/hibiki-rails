// DOM → server: how a control's event becomes a channel action.
import { beforeEach, afterEach, describe, expect, it, vi } from "vitest"
import { island, mount, unmount, performed, subscriptions } from "./support/island.js"

beforeEach(() => vi.useFakeTimers())
afterEach(async () => {
  await unmount()
  vi.useRealTimers()
})

describe("subscribe params", () => {
  it("sends channel and cid", async () => {
    await mount(island(""))
    expect(subscriptions[0].params).toEqual({ channel: "TestChannel", cid: "c1" })
  })

  it("merges extra params from the island", async () => {
    await mount(island("", `data-hibiki-params-value='{"record_id":7}'`))
    expect(subscriptions[0].params).toEqual({
      channel: "TestChannel",
      cid: "c1",
      record_id: 7
    })
  })

  // Params are client-supplied. A page must not be able to point its
  // subscription at another channel or steal another tab's graph.
  it("never lets a param override channel or cid", async () => {
    await mount(
      island("", `data-hibiki-params-value='{"channel":"AdminChannel","cid":"other"}'`)
    )
    expect(subscriptions[0].params).toEqual({ channel: "TestChannel", cid: "c1" })
  })
})

describe("token matching", () => {
  it("performs the action named for the fired event", async () => {
    const root = await mount(island(`<button data-hibiki-on="click->increment"></button>`))
    root.querySelector("button").click()
    expect(performed).toEqual([["increment", {}]])
  })

  it("ignores an event with no matching token", async () => {
    const root = await mount(island(`<button data-hibiki-on="change->x"></button>`))
    root.querySelector("button").click()
    expect(performed).toEqual([])
  })

  it("dispatches each of several tokens on one element by event type", async () => {
    const root = await mount(
      island(`<button data-hibiki-on="click->load_more visible->load_more"></button>`)
    )
    root.querySelector("button").click()
    expect(performed).toEqual([["load_more", {}]])
  })

  it("merges the with: payload", async () => {
    const root = await mount(
      island(`<button data-hibiki-on="click->destroy" data-hibiki-with='{"id":7}'></button>`)
    )
    root.querySelector("button").click()
    expect(performed).toEqual([["destroy", { id: 7 }]])
  })

  // Events bubble to every ancestor island's listener, so each controller
  // must act only on the controls it owns — or a nested island's click
  // performs twice, once per channel.
  it("ignores a control owned by a nested island", async () => {
    await mount(
      island(
        island(`<button data-hibiki-on="click->inner"></button>`).replace(
          'data-hibiki-cid-value="c1"',
          'data-hibiki-cid-value="c2"'
        )
      )
    )
    document.querySelector("button").click()
    expect(performed).toEqual([["inner", {}]])
  })
})

describe("changed control payloads", () => {
  const change = (control) => control.dispatchEvent(new Event("change", { bubbles: true }))

  it("sends a text input's value under its name", async () => {
    const root = await mount(
      island(`<input name="q" data-hibiki-on="change->search">`)
    )
    const input = root.querySelector("input")
    input.value = "earthsea"
    change(input)
    expect(performed).toEqual([["search", { q: "earthsea" }]])
  })

  // A checkbox's `value` is its value ATTRIBUTE: reading it made checking
  // and unchecking send byte-identical payloads, which is why inline
  // boolean toggles had to be buttons with the server owning the flip.
  it("sends a checkbox's checked state, not its value attribute", async () => {
    const root = await mount(
      island(`<input type="checkbox" name="available" value="1"
                     data-hibiki-on="change->set_available">`)
    )
    const box = root.querySelector("input")
    box.checked = true
    change(box)
    box.checked = false
    change(box)
    expect(performed).toEqual([
      ["set_available", { available: true }],
      ["set_available", { available: false }]
    ])
  })

  it("sends a multi-select's selected values as an array", async () => {
    const root = await mount(
      island(`<select name="tags" multiple data-hibiki-on="change->set_tags">
                <option value="a"></option><option value="b"></option>
                <option value="c"></option>
              </select>`)
    )
    const select = root.querySelector("select")
    select.options[0].selected = true
    select.options[2].selected = true
    change(select)
    expect(performed).toEqual([["set_tags", { tags: ["a", "c"] }]])
  })

  // change fires on the newly-checked radio, so value is already correct.
  it("sends the newly checked radio's value", async () => {
    const root = await mount(
      island(`<input type="radio" name="sort" value="title"
                     data-hibiki-on="change->set_sort">`)
    )
    const radio = root.querySelector("input")
    radio.checked = true
    change(radio)
    expect(performed).toEqual([["set_sort", { sort: "title" }]])
  })

  it("sends an input event's value the same way", async () => {
    const root = await mount(
      island(`<input name="q" data-hibiki-on="input->search">`)
    )
    const input = root.querySelector("input")
    input.value = "ged"
    input.dispatchEvent(new Event("input", { bubbles: true }))
    expect(performed).toEqual([["search", { q: "ged" }]])
  })
})

describe("submit", () => {
  const submit = (form) => form.dispatchEvent(new Event("submit", { bubbles: true, cancelable: true }))

  it("sends the form's FormData on top of with:", async () => {
    const root = await mount(
      island(`<form data-hibiki-on="submit->save" data-hibiki-with='{"id":7}'>
                <input name="title" value="Ice Fire">
              </form>`)
    )
    submit(root.querySelector("form"))
    expect(performed).toEqual([["save", { id: 7, title: "Ice Fire" }]])
  })

  it("resets the form by default", async () => {
    const root = await mount(
      island(`<form data-hibiki-on="submit->add"><input name="title" value=""></form>`)
    )
    const form = root.querySelector("form")
    form.querySelector("input").value = "typed"
    submit(form)
    expect(form.querySelector("input").value).toBe("")
  })

  // Reset runs synchronously, before the server has replied — so on an edit
  // form a failed commit would discard what the user typed.
  it("keeps the inputs when reset is false", async () => {
    const root = await mount(
      island(`<form data-hibiki-on="submit->save" data-hibiki-reset="false">
                <input name="title" value="">
              </form>`)
    )
    const form = root.querySelector("form")
    form.querySelector("input").value = "typed"
    submit(form)
    expect(form.querySelector("input").value).toBe("typed")
    expect(performed).toEqual([["save", { title: "typed" }]])
  })

  it("prevents the browser's own submit", async () => {
    const root = await mount(island(`<form data-hibiki-on="submit->save"></form>`))
    const event = new Event("submit", { bubbles: true, cancelable: true })
    root.querySelector("form").dispatchEvent(event)
    expect(event.defaultPrevented).toBe(true)
  })
})

describe("confirm", () => {
  it("performs when accepted", async () => {
    vi.stubGlobal("confirm", () => true)
    const root = await mount(
      island(`<button data-hibiki-on="click->destroy"
                      data-hibiki-confirm="Are you sure?"></button>`)
    )
    root.querySelector("button").click()
    expect(performed).toEqual([["destroy", {}]])
    vi.unstubAllGlobals()
  })

  it("performs nothing when declined", async () => {
    vi.stubGlobal("confirm", () => false)
    const root = await mount(
      island(`<button data-hibiki-on="click->destroy"
                      data-hibiki-confirm="Are you sure?"></button>`)
    )
    root.querySelector("button").click()
    expect(performed).toEqual([])
    vi.unstubAllGlobals()
  })

  // The preventDefault has to happen before the confirm gate, or declining
  // lets the form navigate away.
  it("still prevents the browser submit when declined", async () => {
    vi.stubGlobal("confirm", () => false)
    const root = await mount(
      island(`<form data-hibiki-on="submit->save" data-hibiki-confirm="Sure?"></form>`)
    )
    const event = new Event("submit", { bubbles: true, cancelable: true })
    root.querySelector("form").dispatchEvent(event)
    expect(event.defaultPrevented).toBe(true)
    expect(performed).toEqual([])
    vi.unstubAllGlobals()
  })
})

describe("debounce", () => {
  const type = (input, text) => {
    input.value = text
    input.dispatchEvent(new Event("input", { bubbles: true }))
  }

  it("collapses a burst into one perform carrying the final value", async () => {
    const root = await mount(
      island(`<input name="q" data-hibiki-on="input->search" data-hibiki-debounce="250">`)
    )
    const input = root.querySelector("input")
    for (const text of ["e", "ea", "ear", "eart", "earth"]) type(input, text)

    expect(performed).toEqual([])
    await vi.advanceTimersByTimeAsync(250)
    expect(performed).toEqual([["search", { q: "earth" }]])
  })

  it("performs again once the wait has elapsed", async () => {
    const root = await mount(
      island(`<input name="q" data-hibiki-on="input->search" data-hibiki-debounce="250">`)
    )
    const input = root.querySelector("input")
    type(input, "a")
    await vi.advanceTimersByTimeAsync(250)
    type(input, "ab")
    await vi.advanceTimersByTimeAsync(250)

    expect(performed).toEqual([
      ["search", { q: "a" }],
      ["search", { q: "ab" }]
    ])
  })

  it("debounces each control independently", async () => {
    const root = await mount(
      island(`<input name="q" data-hibiki-on="input->search" data-hibiki-debounce="250">
              <input name="note" data-hibiki-on="input->set_note" data-hibiki-debounce="250">`)
    )
    const [q, note] = root.querySelectorAll("input")
    type(q, "x")
    type(note, "y")
    await vi.advanceTimersByTimeAsync(250)

    expect(performed).toEqual([
      ["search", { q: "x" }],
      ["set_note", { note: "y" }]
    ])
  })

  it("drops a pending action when the island disconnects", async () => {
    const root = await mount(
      island(`<input name="q" data-hibiki-on="input->search" data-hibiki-debounce="250">`)
    )
    type(root.querySelector("input"), "gone")
    await unmount()
    await vi.advanceTimersByTimeAsync(250)

    expect(performed).toEqual([])
  })
})
