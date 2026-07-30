# Changelog

The gem and the npm package are released in lockstep and share these version
numbers — `app/assets/javascripts/hibiki.js` is a single copy served both ways,
so importmap and bundler apps always resolve identical client code.

## Unreleased

### Added

**`hibiki:rails:scaffold` and `hibiki:rails:scaffold_controller`** — a reactive
CRUD resource generated the way `rails g scaffold` generates a plain one.

```sh
bin/rails g hibiki:rails:scaffold Book title:string author:references
bin/rails g hibiki:rails:scaffold_controller Book   # an existing model
```

The generated index is live: search, filter, sort and pagination are signal
state rather than page loads, rows edit in place, and a write from anywhere —
another tab, another user, the plain controller, a console — repaints every open
list. Everything is derived from the model's schema (columns, types, `belongs_to`
reflections, validators) or from the same `NAME field:type` argument list Rails'
own scaffold takes.

Stock `rails g scaffold` is untouched; these live under their own namespace.

Options: `--css=daisyui|tailwind|none` (detected when absent),
`--infinite-scroll`, `--skip-pagination`, `--skip-search`, `--page-size=N`,
`--skip-routes`.

Two notes on what it does to an app you already have. The **model is modified** —
one `delegate` per `belongs_to`, plus the `after_commit` broadcast the whole
thing hangs off — and the generator says so when it happens. And **restart the
server afterwards**: `app/forms/` is likely new, and Rails computes autoload
paths from the `app/*` glob at boot.

## 0.3.0 — 2026-07-28

### Security

**Channel lifecycle methods were client-invocable on Rails 7.1 and 7.2.**
Upgrade if you run hibiki_rails on either. Rails 8.x apps were never affected.

ActionCable builds a channel's client-invocable actions from the public methods
the class adds. The gem subtracted its lifecycle hooks through ActionCable's
`internal_methods` hook — but **that hook only exists on Rails 8.x**; on 7.1 and
7.2 `action_methods` never consults it, so the override was silently inert and
the hooks stayed exposed.

Reachable by any client that can open a subscription, against its own
connection's graph. There is no cross-connection or cross-user data exposure;
the impact is resource exhaustion:

- `perform("build_graph")` — exposed on **every** affected app, since
  `#build_graph` is always public. It re-runs the graph build outside
  `Hibiki.root`, so the effects it creates are unowned and the dispose on
  unsubscribe never reaches them, while the previous root is still held. Each
  call leaks; repeated calls grow memory without bound.
- `perform("subscribed")` — exposed only where an app defined `#subscribed`
  public, which the ActiveRecord guide's own `after_commit` example did until
  this release. It allocates a second `GraphActor` — a new **thread** — and
  overwrites the reference to the first, so the original is never stopped.
  Repeated calls exhaust the process's threads.

Fixed by subtracting in `action_methods` itself, which works on every supported
version:

```ruby
HIDDEN_ACTIONS = %w[build_graph subscribed unsubscribed].freeze
def action_methods = super - HIDDEN_ACTIONS
```

No application change is required. Writing `#subscribed` and `#unsubscribed`
private is still the better habit, because it also protects the methods this
list does not know about — the guides now show them that way.

### Added

- `on(action, event:)` takes an **event list**, so one element can answer
  several events: `on(:load_more, event: %i[click visible])`.
- **`input`** joins the delegated events, with a per-control **`debounce:`**.
  `:input` carries 250 ms unless told otherwise (`debounce: 0` opts out); the
  value is stamped into the markup rather than being an invisible client
  default.
- **`visible`**, a pseudo-event backed by an `IntersectionObserver`, so a
  load-more control can double as an infinite-scroll sentinel. It fires once
  per observation and re-attaches to the replacement element after each
  fragment swap.
- **`confirm:`** on `on(...)` — a `window.confirm` gate. `data-turbo-confirm`
  does nothing on a hibiki control, since it is not a Turbo-driven form.
- **`reset: false`** on a submit, to keep a form's inputs. The default resets
  them synchronously, before the server has replied, which is right for an
  "add" form and destroys an edit form's contents on a failed commit.
- **Subscribe params**: `hibiki_island(channel, cid:, params: { record_id: })`
  reach the channel as `params[:key]`, which is how a channel learns which
  record its page is about. They are client-supplied and untrusted — use one
  only to look up a record inside a scope the channel chooses, and never
  interpolate one into a streamable name. They cannot override `channel` or
  `cid`.
- The client has its own test suite (`spec/js`, vitest + happy-dom) and a CI
  job, plus a pinned Rails 8.1 matrix leg.

### Changed

- **A changed checkbox now sends its checked state as a boolean**, and a
  multi-select sends an array of its selected values. Previously both sent
  `control.value` — the value *attribute* — so checking and unchecking a
  checkbox produced byte-identical payloads. **This is a payload shape
  change**: an action reading a `change` payload for a checkbox now receives
  `true`/`false` rather than `"1"`. The form-submit path is unaffected.
- `transmit_value` is **equality-gated**: an effect re-runs whenever any signal
  it read changed, so a bumped version token used to re-send every reactive
  value's text even when byte-identical. The block still runs unconditionally,
  so dependency collection is unchanged — only the transmit is skipped. If you
  render a reactive placeholder *inside* a broadcast-replaced fragment, render
  it with its current value: the swap resets the DOM text and the gate now
  suppresses the re-send that used to heal it.
- Each graph job runs inside `Rails.application.executor`, so
  `CurrentAttributes` are reset between jobs, autoloads are safe off the main
  thread, and each job gets its own query cache.
- Graph-thread errors are **logged** in development and test.
  `ActiveSupport::ErrorReporter` has no subscribers by default, so in a stock
  app these previously vanished entirely — no line, no stack, just a fragment
  that stopped updating. Production behaviour is unchanged.

## 0.2.0 — 2026-07-21

- Reactive values: `reactive` / `reactive_attrs` / `transmit_value`, matched
  document-wide so a value can render outside the island that computes it.
- `Components::` namespacing for the Phlex generator.

## 0.1.0 — 2026-07-18

Initial release.
