// The motion module: a render that would remove a marked element is held
// until the element's transitions finish, and a marked element the render
// inserted is bracketed by data-motion-entering.
//
// happy-dom has no Element.getAnimations and no layout, so each example that
// needs a transition stubs getAnimations on the element with a promise it
// controls; requestAnimationFrame is a 16 ms timer under fake timers, so "one
// frame" is a statement about time rather than a real paint.
import { beforeEach, afterEach, describe, expect, it, vi } from "vitest"
import { island, mount, unmount, controller, sent, receive, flush, cable, subscriptions } from "./support/island.js"

const FRAME = 16
const CEILING = 1000
const GRACE = 60

let raf

beforeEach(async () => {
  vi.useFakeTimers()
  raf = vi.fn((callback) => setTimeout(() => callback(performance.now()), FRAME))
  vi.stubGlobal("requestAnimationFrame", raf)
  await import("../../app/assets/javascripts/hibiki-motion.js")
})

afterEach(async () => {
  // Drain any hold still pending (its ceiling), so the module's queue never
  // carries one example's wait into the next.
  await vi.advanceTimersByTimeAsync(CEILING + FRAME)
  await unmount()
  delete document.visibilityState
  vi.restoreAllMocks()
  vi.unstubAllGlobals()
  vi.useRealTimers()
})

const frame = () => vi.advanceTimersByTimeAsync(FRAME)
const leaving = (element) => element.hasAttribute("data-motion-leaving")
const entering = (element) => element.hasAttribute("data-motion-entering")
const $ = (id) => document.getElementById(id)

// A transition on the element that ends when the returned function is called.
const animate = (element) => {
  let finish
  const animation = { finished: new Promise((resolve) => { finish = resolve }) }
  element.getAnimations = () => [animation]
  return finish
}

// happy-dom serves visibilityState from deep in its prototype chain; an own
// property shadows it, and afterEach removes it again.
const hide = () => Object.defineProperty(document, "visibilityState", { value: "hidden", configurable: true })

const row = (id, mark = "", inner = "") =>
  `<div id="${id}" data-motion${mark ? `="${mark}"` : ""}>${inner}<button id="${id}_destroy" data-hibiki-on="click->destroy"></button></div>`
const list = (inner = "") => `<div id="list">${inner}</div>`

// What Turbo's StreamActions do, for the actions these examples use.
const apply = (stream) => {
  if (stream.action === "refresh") return
  const content = stream.templateElement.content
  for (const target of stream.targetElements) {
    switch (stream.action) {
      case "replace": target.replaceWith(content.cloneNode(true)); break
      case "update": target.replaceChildren(content.cloneNode(true)); break
      case "remove": target.remove(); break
      case "append": target.append(content.cloneNode(true)); break
      case "prepend": target.prepend(content.cloneNode(true)); break
    }
  }
}

// A <turbo-stream> as Turbo dispatches it: the event carries the stream and
// a render Turbo will await once the event has been heard. `done` is that
// await.
const stream = ({ action, target, html = "", keep = false }) => {
  const template = document.createElement("template")
  template.innerHTML = html
  const element = {
    action,
    target,
    templateElement: template,
    get targetElements() {
      if (action === "refresh") throw new Error("refresh has no target")
      const found = $(target)
      return found ? [found] : []
    }
  }
  const render = vi.fn(async (stream) => { if (!keep) apply(stream) })
  const event = new CustomEvent("turbo:before-stream-render", {
    bubbles: true,
    detail: { newStream: element, render }
  })
  document.dispatchEvent(event)
  return { render, event, done: event.detail.render(element) }
}

describe("the gate", () => {
  // The islands' own wrappers are async but call through synchronously; only
  // the module's queue would defer the render to a microtask.
  it("leaves a render alone when nothing on either side is marked", async () => {
    await mount(island(list("<p>plain</p>")))
    const { render } = stream({ action: "replace", target: "list", html: list() })
    expect(render).toHaveBeenCalledTimes(1)
    expect(raf).not.toHaveBeenCalled()
  })

  it("swaps a transmit fragment synchronously when nothing is marked", async () => {
    await mount(island(list("old")))
    subscriptions.at(-1).handlers.received({ html: list("new") })
    expect($("list").textContent).toBe("new")
  })

  it("routes a render through when only the incoming content is marked", async () => {
    await mount(island(list()))
    const { done } = stream({ action: "replace", target: "list", html: list(row("r1")) })
    await done
    expect(entering($("r1"))).toBe(true)
  })
})

describe("leaving, over Turbo", () => {
  it("holds a replace that drops a marked element until its transition ends", async () => {
    await mount(island(list(row("r1"))))
    const finish = animate($("r1"))
    const { render } = stream({ action: "replace", target: "list", html: list() })
    await flush()

    expect(leaving($("r1"))).toBe(true)
    expect(render).not.toHaveBeenCalled()
    await frame()
    expect(render).not.toHaveBeenCalled()

    finish()
    await flush()
    expect(render).toHaveBeenCalledTimes(1)
    expect($("r1")).toBeNull()
  })

  it("does not hold when the incoming content keeps the id", async () => {
    await mount(island(list(row("r1"))))
    animate($("r1"))
    const { render, done } = stream({ action: "replace", target: "list", html: list(row("r1")) })
    await done
    expect(render).toHaveBeenCalledTimes(1)
    expect(raf).not.toHaveBeenCalled()
  })

  it("update: descendants leave, the target itself stays", async () => {
    await mount(island(`<div id="list" data-motion>${row("r1")}</div>`))
    animate($("r1"))
    stream({ action: "update", target: "list", html: "" })
    await flush()
    expect(leaving($("r1"))).toBe(true)
    expect(leaving($("list"))).toBe(false)
  })

  it("remove: the target leaves", async () => {
    await mount(island(list(row("r1"))))
    const finish = animate($("r1"))
    const { render } = stream({ action: "remove", target: "r1" })
    await flush()
    expect(leaving($("r1"))).toBe(true)
    await frame()
    finish()
    await flush()
    expect(render).toHaveBeenCalledTimes(1)
    expect($("r1")).toBeNull()
  })

  it("append and prepend remove nothing, so nothing leaves", async () => {
    await mount(island(list(row("r1"))))
    animate($("r1"))
    const { render, done } = stream({ action: "append", target: "list", html: row("r2") })
    await done
    expect(leaving($("r1"))).toBe(false)
    expect(render).toHaveBeenCalledTimes(1)
    expect($("r2")).not.toBeNull()
  })

  it("survives a refresh stream, which has no target", async () => {
    await mount(island(list(row("r1"))))
    const { render, done } = stream({ action: "refresh" })
    await done
    expect(render).toHaveBeenCalledTimes(1)
  })

  it("stamps only the outermost of nested marked elements", async () => {
    await mount(island(list(row("r1", "", `<div id="c1" data-motion></div>`))))
    animate($("r1"))
    stream({ action: "replace", target: "list", html: list() })
    await flush()
    expect(leaving($("r1"))).toBe(true)
    expect(leaving($("c1"))).toBe(false)
  })

  it("proceeds after one frame when the element has no getAnimations", async () => {
    await mount(island(list(row("r1"))))
    expect($("r1").getAnimations).toBeUndefined()
    const { render } = stream({ action: "replace", target: "list", html: list() })
    await flush()
    expect(render).not.toHaveBeenCalled()
    await frame()
    await flush()
    expect(render).toHaveBeenCalledTimes(1)
  })

  it("clears the stamp when the render kept the element after all", async () => {
    await mount(island(list(row("r1"))))
    const finish = animate($("r1"))
    stream({ action: "replace", target: "list", html: list(), keep: true })
    await flush()
    await frame()
    finish()
    await flush()
    expect($("r1")).not.toBeNull()
    expect(leaving($("r1"))).toBe(false)
  })
})

describe("a hidden document and the ceiling", () => {
  it("waits for no frame when the document is hidden", async () => {
    await mount(island(list(row("r1"))))
    hide()
    animate($("r1"))
    const { render } = stream({ action: "replace", target: "list", html: list() })
    await flush()
    expect(render).toHaveBeenCalledTimes(1)
    expect(raf).not.toHaveBeenCalled()
  })

  it("renders at the ceiling when a transition never ends", async () => {
    await mount(island(list(row("r1"))))
    animate($("r1"))
    const { render } = stream({ action: "replace", target: "list", html: list() })
    await flush()
    await vi.advanceTimersByTimeAsync(CEILING - 1)
    expect(render).not.toHaveBeenCalled()
    await vi.advanceTimersByTimeAsync(1)
    expect(render).toHaveBeenCalledTimes(1)
  })
})

describe("the queue", () => {
  it("applies renders in arrival order, a later one waiting out a hold", async () => {
    await mount(island(list(row("r1"))))
    const finish = animate($("r1"))
    const first = stream({ action: "replace", target: "list", html: list() })
    const second = stream({ action: "append", target: "list", html: "<p id='p'></p>" })
    await flush()
    await frame()
    expect(second.render).not.toHaveBeenCalled()

    finish()
    await flush()
    expect(first.render).toHaveBeenCalledTimes(1)
    expect(second.render).toHaveBeenCalledTimes(1)
    expect(first.render.mock.invocationCallOrder[0]).toBeLessThan(second.render.mock.invocationCallOrder[0])
    expect($("p")).not.toBeNull()
  })

  it("holds once per render however many islands are on the page, and they count the paint after it", async () => {
    await mount(island(list(row("r1"))) + island(`<div id="other"></div>`))
    const [a, b] = [...document.querySelectorAll('[data-controller~="hibiki"]')].map(controller)
    const finish = animate($("r1"))
    const { render } = stream({ action: "replace", target: "list", html: list() })
    await flush()
    await frame()
    expect(a.renders).toBe(0)
    expect(b.renders).toBe(0)

    finish()
    await flush()
    expect(render).toHaveBeenCalledTimes(1)
    expect(a.renders).toBe(1)
    expect(b.renders).toBe(1)
  })

  it("queues a transmit swap behind a Turbo hold", async () => {
    await mount(island(list(row("r1")) + `<div id="other">old</div>`))
    const finish = animate($("r1"))
    stream({ action: "replace", target: "list", html: list() })
    await flush()
    subscriptions.at(-1).handlers.received({ html: `<div id="other">new</div>` })
    await flush()
    await frame()
    expect($("other").textContent).toBe("old")

    finish()
    await flush()
    expect($("other").textContent).toBe("new")
  })
})

describe("data-motion=\"own\"", () => {
  const destroyed = () => stream({ action: "replace", target: "list", html: list() })

  it("leaves when an in-flight trip's control is inside it", async () => {
    await mount(island(list(row("r1", "own"))))
    animate($("r1"))
    $("r1_destroy").click()
    destroyed()
    await flush()
    expect(leaving($("r1"))).toBe(true)
  })

  it("leaves when the last gesture's control is inside it, even after its trip settled", async () => {
    const root = await mount(island(list(row("r1", "own"))))
    animate($("r1"))
    $("r1_destroy").click()
    await receive({ ack: sent[0][1].hbk })
    await vi.advanceTimersByTimeAsync(GRACE)
    expect(controller(root).busy.size).toBe(0)

    destroyed()
    await flush()
    expect(leaving($("r1"))).toBe(true)
  })

  it("goes at once when nothing inside it fired", async () => {
    await mount(island(list(row("r1", "own"))))
    animate($("r1"))
    const { render } = destroyed()
    await flush()
    expect(render).toHaveBeenCalledTimes(1)
    expect($("r1")).toBeNull()
    expect(raf).not.toHaveBeenCalled()
  })

  it("does not leave for a gesture outside it", async () => {
    await mount(island(`<input id="q" data-hibiki-on="input->search">` + list(row("r1", "own"))))
    animate($("r1"))
    $("q").dispatchEvent(new Event("input", { bubbles: true }))
    expect(sent.length).toBe(1)
    const { render } = destroyed()
    await flush()
    expect(render).toHaveBeenCalledTimes(1)
    expect($("r1")).toBeNull()
    expect(raf).not.toHaveBeenCalled()
  })

  it("consumes the gesture with the render that follows it", async () => {
    await mount(island(list(row("r1", "own"))))
    animate($("r1"))
    $("r1_destroy").click()
    await receive({ ack: sent[0][1].hbk })
    await vi.advanceTimersByTimeAsync(GRACE)
    const passing = stream({ action: "append", target: "list", html: "<p></p>" })
    await passing.done

    const { render } = destroyed()
    await flush()
    expect(render).toHaveBeenCalledTimes(1)
    expect($("r1")).toBeNull()
    expect(raf).not.toHaveBeenCalled()
  })

  it("still counts a gesture whose send died on the socket", async () => {
    await mount(island(list(row("r1", "own"))))
    animate($("r1"))
    cable.sendResult = false
    $("r1_destroy").click()
    destroyed()
    await flush()
    expect(leaving($("r1"))).toBe(true)
  })

  // No generic island contains the element — a ChannelController subclass
  // drives it, or nothing does — so islandFor finds no trip records. That is
  // no evidence of a gesture, not a plain mark: the element goes at once,
  // even when something inside it was clicked.
  it("never leaves outside any generic island, even after a click inside it", async () => {
    await mount(list(row("r1", "own")))
    animate($("r1"))
    $("r1_destroy").click()
    const { render } = destroyed()
    await flush()
    expect(render).toHaveBeenCalledTimes(1)
    expect($("r1")).toBeNull()
    expect(raf).not.toHaveBeenCalled()
  })

  it("still holds a plain mark outside any generic island", async () => {
    await mount(list(row("r1")))
    const finish = animate($("r1"))
    destroyed()
    await flush()
    expect(leaving($("r1"))).toBe(true)
    await frame()
    finish()
    await flush()
    expect($("r1")).toBeNull()
  })
})

describe("entering", () => {
  it("brackets a marked element the render inserted until its transition ends", async () => {
    await mount(island(list()))
    let finish
    const animation = { finished: new Promise((resolve) => { finish = resolve }) }
    Element.prototype.getAnimations = () => [animation]
    try {
      const { done } = stream({ action: "replace", target: "list", html: list(row("r1")) })
      await done
      expect(entering($("r1"))).toBe(true)
      await frame()
      expect(entering($("r1"))).toBe(true)
      finish()
      await flush()
      expect(entering($("r1"))).toBe(false)
    } finally {
      delete Element.prototype.getAnimations
    }
  })

  it("does not stamp an element whose id was already present", async () => {
    await mount(island(list(row("r1"))))
    const { done } = stream({ action: "replace", target: "list", html: list(row("r1")) })
    await done
    expect(entering($("r1"))).toBe(false)
  })

  it("stamps only the outermost of nested new marked elements", async () => {
    await mount(island(list()))
    const { done } = stream({
      action: "replace", target: "list", html: list(row("r1", "", `<div id="c1" data-motion></div>`))
    })
    await done
    expect(entering($("r1"))).toBe(true)
    expect(entering($("c1"))).toBe(false)
  })

  it("clears at once in a hidden document", async () => {
    await mount(island(list()))
    hide()
    const { done } = stream({ action: "replace", target: "list", html: list(row("r1")) })
    await done
    await flush()
    expect(entering($("r1"))).toBe(false)
    expect(raf).not.toHaveBeenCalled()
  })
})

describe("over the transmit transport", () => {
  it("holds the swap while a marked descendant leaves", async () => {
    await mount(island(list(row("r1"))))
    const finish = animate($("r1"))
    subscriptions.at(-1).handlers.received({ html: list("<p id='p'></p>") })
    await flush()
    expect(leaving($("r1"))).toBe(true)
    expect($("p")).toBeNull()

    await frame()
    finish()
    await flush()
    expect($("p")).not.toBeNull()
    expect($("r1")).toBeNull()
  })

  it("never treats the fragment's root as leaving", async () => {
    await mount(island(`<div id="list" data-motion>old</div>`))
    animate($("list"))
    subscriptions.at(-1).handlers.received({ html: `<div id="list" data-motion>new</div>` })
    await flush()
    expect($("list").textContent).toBe("new")
    expect(raf).not.toHaveBeenCalled()
  })

  it("applies the own policy from the island that received", async () => {
    await mount(island(list(row("r1", "own"))))
    animate($("r1"))
    $("r1_destroy").click()
    subscriptions.at(-1).handlers.received({ html: list() })
    await flush()
    expect(leaving($("r1"))).toBe(true)
  })

  it("rescans sentinels only after the held swap landed", async () => {
    const observed = []
    vi.stubGlobal("IntersectionObserver", class {
      observe(target) { observed.push(target) }
      unobserve() {}
      disconnect() {}
    })
    await mount(island(list(row("r1"))))
    const finish = animate($("r1"))
    subscriptions.at(-1).handlers.received({
      html: list(`<button id="more" data-hibiki-on="visible->load_more"></button>`)
    })
    await flush()
    await frame()
    expect(observed).toEqual([])

    finish()
    await flush()
    expect(observed).toEqual([$("more")])
  })
})

describe("with the busy machine", () => {
  it("lets an ack settle a trip while its render is still held", async () => {
    const root = await mount(island(list(row("r1", "own"))))
    animate($("r1"))
    $("r1_destroy").click()
    stream({ action: "replace", target: "list", html: list() })
    await flush()
    expect(leaving($("r1"))).toBe(true)

    await receive({ ack: sent[0][1].hbk })
    await vi.advanceTimersByTimeAsync(GRACE)
    expect(controller(root).busy.size).toBe(0)
    expect(leaving($("r1"))).toBe(true)
  })
})

describe("the client's seams", () => {
  it("exports islandFor, the containing generic island", async () => {
    const root = await mount(island(list(row("r1"))))
    const { islandFor } = await import("../../app/assets/javascripts/hibiki.js")
    expect(islandFor($("r1"))).toBe(controller(root))
    expect(islandFor(document.body)).toBeUndefined()
  })

  it("dispatches hibiki:before-render with a replaceable render", async () => {
    const root = await mount(island(list("old")))
    const seen = []
    root.addEventListener("hibiki:before-render", (event) => {
      seen.push({ island: event.detail.island, id: event.detail.content.firstElementChild.id })
      const { render } = event.detail
      event.detail.render = () => { seen.push("held"); render() }
    })
    subscriptions.at(-1).handlers.received({ html: list("new") })
    expect(seen[0]).toEqual({ island: controller(root), id: "list" })
    expect(seen[1]).toBe("held")
    expect($("list").textContent).toBe("new")
  })
})
