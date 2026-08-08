# Changelog

The gem and the npm package are released in lockstep and share these version
numbers — `app/assets/javascripts/hibiki.js` is a single copy served both ways,
so importmap and bundler apps always resolve identical client code.

## 0.5.1 — 2026-08-08

### Changed

**Generator output and messages slimmed down.** The scaffold templates used to
carry long design-rationale comments into every generated file; they are now
one-to-three-line hints, with the docs holding the prose. The safety notes a
user editing the file actually needs stayed: public channel methods are
client-invocable actions, ActionCable's exact-arity rule, the untrusted
subscribe param, Phlex omitting `false`-valued attributes, and the busy
stylesheet's do-not-wrap-in-a-layer rule.

The generators' status notices were shortened the same way — they still say
what to do, just not why at essay length.

No behavior change anywhere: no code inside any template moved, and neither
the runtime nor the packaged client changed (the npm 0.5.1 exists only to keep
the lockstep rule). Re-running a scaffold with `--force` rewrites the views
with the shorter comments; that diff is the whole upgrade.

## 0.5.0 — 2026-08-05

### Added

**`--phlex` on both scaffold generators.** `bin/rails g hibiki:rails:scaffold
Book title:string --phlex` emits Phlex components under `app/views/books/*.rb`,
namespaced `Views::`, instead of ERB templates. Purely additive: without the
flag nothing about the generated output changes, byte for byte.

Only the view layer moves. The channels, the query object, the ReactiveForm,
the model injections, every action and the whole `data-hibiki-*` protocol are
the same either way — the controller gains an explicit `render Views::…` at
each of its six render sites, and the two `broadcast_morph` calls swap
`partial:`/`locals:` for `renderable:`, and that is the entire difference
outside the templates.

Needs `phlex-rails` and `bin/rails g phlex:install`. The generator warns when
either is missing and writes the files anyway, so the scaffold can come first.

Four things worth knowing, because they are not what an ERB reader expects.
Phlex renders `String`, `Symbol`, `Integer` and `Float` and raises on anything
else, so date, time and decimal columns are emitted with an explicit `to_s`.
Phlex omits a `false`-valued attribute entirely, so the page control's
`data-turbo` is the string `"false"`. Phlex emits no whitespace between
siblings, so the components space their inline neighbours explicitly. And
`options_for_select` outputs directly and raises if its return value is passed
on, so both select sites take their options from a block.

The page control is still the one component with a per-`--css` fork, in both
trees. Under Phlex the plain-Tailwind fork's *reason* dissolves — a hoisted
template local becomes an ordinary constant — but it stays forked so the two
trees match file for file and a future `--css` decision stays a diff rather
than a judgement call.

### Changed

**The loading and connection recipes are an asset, not a partial.** They were a
103-line inline `<style>` emitted as `app/views/<resource>/_busy.html.erb` and
rendered once per page; they are now
`app/assets/stylesheets/hibiki_busy.css`, written once per app.

Per resource was always wrong: every rule keys on an attribute the client
stamps and none of them mentions a model, so a two-resource app carried two
byte-identical copies. It also put CSS somewhere a Content-Security-Policy that
forbids inline styles would reject.

The generator wires it for you: a cssbundling or tailwindcss-rails entry
stylesheet gets an `@import`, a layout already using
`stylesheet_link_tag :app` or `:all` needs nothing, and anything else gets a
`stylesheet_link_tag` injected into the layout. Only when none of those applies
does it print the line to add. Every branch is idempotent.

**If you re-run the generator on an app scaffolded before this**, the old
`_busy.html.erb` stays on disk — a generator never deletes — and nothing
renders it any more. The post-install output names it; delete it.

The rules are deliberately unlayered, and the file says so: two of them set
`display` on elements that also carry Tailwind utilities, and unlayered
declarations beat `@layer utilities` whatever the link order.

### Fixed

**The npm package no longer drags in a second copy of `@rails/actioncable`.**
It moves from `dependencies` to `peerDependencies` at `>= 7.0`, matching
turbo-rails' own range.

Why there were two: `@rails/actioncable`'s npm `latest` dist-tag is 7.2.302 even
though 8.x is published, and resolvers prefer `latest` when it satisfies the
range. So turbo-rails' `>=7.0` took 7.2.302 while this package's `>= 8.0` was
forced up to 8.1.301, and both ended up in the bundle — about 16 KB of duplicate
client, and two separate module instances that could never share a consumer.
A fresh install happened to hoist a single copy; the duplicate appeared when
adding hibiki-rails to an app whose lockfile already pinned 7.2.302, which is
every existing app.

If your bundler warns about an unmet peer, install `@rails/actioncable`
explicitly — but a stock Rails app already has it via turbo-rails, and both bun
and npm 7+ auto-install a missing peer. The client uses only `createConsumer`,
`subscriptions.create` and `subscription.perform`, all stable since Action
Cable 6, so the lower floor changes nothing at runtime.

### Changed — BREAKING

**The Rails floor is now 8.0.** `actioncable` and `railties` move from
`>= 7.1` to `>= 8.0`, and the 7.1 / 7.2 CI legs are gone. Ruby stays at `>= 3.4`.

This is a correction as much as a policy change: **generated controllers never
ran on Rails 7.** `hibiki:rails:scaffold` emits `params.expect` at two sites,
inherited from Rails 8's own scaffold, and `ActionController::Parameters#expect`
does not exist before 8.0 — so a generated controller raised `NoMethodError` on
the first request to `show`, `edit`, `update`, `create` or `destroy` on 7.1 and
7.2. The generator suite never caught it because those specs assert on emitted
source text and never boot the result.

The alternative — branching the template on `Rails::VERSION` — was rejected: it
would also need a way to *execute* generated output on the old legs, which is
more work than dropping two CI legs for a version combination (Rails 7.x on
Ruby >= 3.4) that barely exists.

**If you are on Rails 7.1 or 7.2, stay on 0.4.0.** It remains available and is
unaffected; nothing in 0.5.0 is a security fix for it. Note that the *runtime*
half of the gem — channels, the graph, the broadcast helpers, the client — has
no known 8.0-only dependency; it is the generators whose output does. The floor
applies to the whole gem anyway, because shipping a gem whose headline generator
cannot run on its own declared floor is what got us here.

## 0.4.0 — 2026-08-03

### Added

**Loading and connection state, stamped by the client.** The first growth of the
`data-hibiki-*` protocol since 0.3.0, and the first attributes in it that no Ruby
helper emits — the client writes them at runtime and app CSS reads them:

```
island root      data-hibiki-busy      present while an action is in flight
                 aria-busy="true"      the same fact, for assistive tech
                 data-hibiki-state     connecting | ready | offline | stalled
firing control   data-hibiki-busy      on the control that started it
```

Everything an app wants out of that is a descendant selector —
`[data-hibiki-busy] .spinner { display: inline-block }` — so per-row and
per-button feedback needs no server state and no `{#if loading}` branch. The
Ruby surface is unchanged: no new option on `on`, `hibiki_island` or `reactive`.

**Actions are acknowledged once their batch has run**, and the ack is what clears
the indicator. It cannot be "clear on the next render": the core's equality gate
(hibiki 0.2.0) lets an ordinary action produce zero bytes — paging to the page
you are already on, a search that does not change the query, a destroy of a row
another tab already deleted — so a render-based rule hangs forever on gestures
users make all the time. The ack sits in an `ensure`, so a raising action stops
the spinner too, and a subscription that has gone away acks `dropped: true` from
the cable thread instead, which is what lets the client tell "late" from "never".

A page running the 0.3.0 client sends no sequence number and gets no ack, so
nothing about this reaches an app that has not upgraded both halves.

**Actions performed before the subscription confirms are queued, not dropped.**
ActionCable's `Subscription#perform` silently returns false on a socket that is
not open yet, and on the Turbo-broadcast path that window is about three
serialised round trips — a click in it used to vanish. The queue covers the first
connect window only: after a reconnect the server rebuilds the graph with default
state, so replaying intent formed against the old one is worse than dropping it,
and the island reads `offline` for the whole gap instead.

Three class properties on `ChannelController` are the entire tuning surface —
`busyDelay` (150 ms before a trip is worth mentioning), `busyGrace` (60 ms for a
broadcast still in flight after its ack), `busyCeiling` (10 s before a trip is
declared stalled rather than cleared silently). Deliberately not Stimulus values
and not helper options; an app that wants different numbers subclasses and
re-registers.

The scaffold generators wire five sites to all of this — the counts line, the
pagination bar, the infinite-scroll sentinel, the destroy button and the
inline-edit Save — through a generated `_busy.html.erb` the app owns.

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

Live per-field validation is derived only from rules the form can actually
evaluate before a round trip: presence, length, and numericality bounds that
carry no `allow_nil:`/`allow_blank:` exemption for the value in hand. A
validator gated on `if:`, `unless:` or `on:` depends on the record rather than
the field, so it contributes nothing live — it still runs at commit and still
lands in `#errors`, which the same per-field slots mirror. The clauses are
generated once; add validators and re-run `scaffold_controller` to pick them up.

**Field order is yours, and choosing it costs nothing.** With no field list the
columns follow the schema, which for an app built from `schema.rb` means
alphabetical. Passing them explicitly picks the order — and against a model that
already exists the generator still reads that model for everything else, so the
live clauses, a number field's `min:`/`max:` and a `belongs_to`'s display label
all survive the choice:

```sh
bin/rails g hibiki:rails:scaffold_controller Author name:string bio:text age:integer
```

A field the model has no column for is still generated, from the argument list
alone, and named in the post-install output — it may be a column whose migration
is still to come, and a silently missing field is the worse failure.

**A unique index with no uniqueness validator is called out.** A database
constraint is not a validator, and the generated form can only mirror what the
model checks — so without one, a duplicate raises `ActiveRecord::RecordNotUnique`
on the graph thread instead of showing a field error, and the round trip
completes having saved nothing. The generator names the column and the exact
`validates` line, for single and composite indexes alike.

Options: `--css=daisyui|tailwind|none` (detected when absent),
`--infinite-scroll`, `--skip-pagination`, `--skip-search`, `--page-size=N`,
`--skip-routes`.

Three notes on what it does to an app you already have.

**The model is modified** — one `delegate` per `belongs_to`, plus the
`after_commit` broadcast the whole thing hangs off.

**So is each model a `belongs_to` points at.** It gains the `has_many` half
Rails' own scaffold never writes (without it the generated destroy button raises
`InvalidForeignKey`) and a ping of its own, because a row prints the parent's
label rather than its id — rename an author and every open books index would
otherwise keep the old name. `dependent:` follows the association: `:destroy`
when it is required, `:nullify` when it is `optional: true`. That ping is
collection-grained, so an open *show* page keeps the old label until reload.

Both injections are idempotent and announced, and anything you already declared
is left alone — including a `dependent:` you chose yourself.

And **restart the server afterwards**: `app/forms/` is likely new, and Rails
computes autoload paths from the `app/*` glob at boot.

### Fixed

**The model injection missed every namespaced model.** Thor anchors
`inject_into_class` on the class name as the file spells it, and the generator
passed the demodulized one — so `app/models/admin/book.rb`, which Rails writes as
`class Admin::Book < ApplicationRecord`, never matched. Silently: Thor rewrote
the file byte-identical and the generator reported a modification. The delegate
never landed, so the show page raised on arrival.

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
