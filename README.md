# hibiki_rails

Rails glue for [hibiki](https://github.com/planetaska/hibiki):
connection-scoped signal graphs over ActionCable, pushing re-rendered HTML to the page — either through Turbo Streams, or over the channel's own subscription to the gem's packaged client (see "The packaged client").

```
cable action arrives → mutate signals → effects render partials →
Turbo Streams broadcast → Turbo morphs the DOM
```

A graph lives per cable connection (in practice: per browser tab), built when the channel subscribes and disposed when it unsubscribes. Effects subscribe to whatever signals they read; when an action writes a signal, exactly the affected effects re-render and broadcast.

Supports Rails >= 7.1, Ruby >= 3.4.

## Installation

Step 1 - Install the gem (`hibiki_rails` depends on the core `hibiki` gem)

```ruby
# Gemfile
gem "hibiki"
gem "hibiki_rails"
```

Or `gem install hibiki hibiki_rails`.

Step 2 - Run the install generator

```sh
bin/rails g hibiki:rails:install
```

The install script will detect if your app is using importmap:

- For importmap apps, the installtion is full-auto, and you don't have to do anything else.
- For apps with JS bundlers (esbuild, bun, etc), you will need to install the companion JS file which is packaged as npm package, and you can install it by running **one of the following**:
  - `npm/yarn install hibiki-rails`
  - `bun add hibiki-rails`
  - or any equivalent for your setup

## Generators

`hibiki_rails` comes battery included. Each supported shape has a generator that scaffolds it as a *working* mini-example — one state, one derived, one action, one effect. Run a generator, render the output from any page, click `+1`, watch it live-update. They are meant to be reshaped in place.

### Stimulus shape generator

```sh
bin/rails g hibiki:rails:stimulus NAME [VIEW_PATH]
```
Generates:

1. One minimal channel in /app/channels
2. One minimal Stimulus ChannelController in /app/javascript/controllers
3. One minimal view partial set (two files) in /app/views/[VIEW_PATH]

Partial example:

```erb
<% cid = local_assigns.fetch(:cid) { SecureRandom.uuid } %>
<div data-controller="counter" data-counter-cid-value="<%= cid %>">
  <%= turbo_stream_from "counter", cid %>

  <%= render "counter/counter_display", count: 0, doubled: 0 %>

  <p><button data-action="counter#increment">+1</button></p>
</div>
```

### Island shape generator

```sh
bin/rails g hibiki:rails:island NAME [VIEW_PATH]
```

Generates:

1. One minimal channel in /app/channels
2. One minimal view partial set (two files) in /app/views/[VIEW_PATH]

Partial example:

```erb
<% cid = local_assigns.fetch(:cid) { SecureRandom.uuid } %>
<%= tag.div(**hibiki_island(CounterChannel, cid:)) do %>
  <%= turbo_stream_from "counter", cid %>

  <%= render "counter/counter_display", count: 0, doubled: 0 %>

  <p><%= tag.button("+1", **on(:increment)) %></p>
<% end %>
```

### Phlex shape generator

```sh
# requires hibiki_phlex gem
bin/rails g hibiki:rails:phlex NAME
```

Generates:

1. One minimal channel in `/app/channels`
2. One minimal Phlex component set (two files) in `/app/commponents/[NAME]`

Phlex component example:

```ruby
class Components::Counter < Phlex::HTML
  state :count, 0
  derived(:doubled) { count * 2 }

  def view_template
    div(id: "counter") do
      p { "count: #{count} · doubled: #{doubled}" }
      button(**on(:increment)) { "+1" }
    end
  end

  def increment
    self.count += 1
  end
end
```

### Rendering generated reactive partial

`VIEW_PATH` is the views directory under `app/views` (defaults to `NAME`); the emitted partial is self-contained, so simply rendering the partial `<%= render "counter/counter" %>` — or `<%= render Components::CounterIsland.new %>` for the Phlex shape — is the only line a page needs.

The `stimulus` shape works with zero wiring; `island` and `phlex` need the one-time `hibiki:rails:install` (they print a hint when it's missing). Namespaced names work (`admin/counter` pins `static channel` where the Stimulus identifier can't infer it). In apps without an importmap (jsbundling/vite), where `controllers/index.js` has no eager loader, the `stimulus` generator also appends the controller's import/register pair to it — and even survives `stimulus:manifest:update`.

## Reactive values

When all you want on the wire is one derived (or state) value — not a whole partial or component — you can skip the fragment class entirely. The view paints named placeholders, and the channel keeps them fresh:

```erb
<!-- Display a single reactive value in the view anywhere -->
<h1>todos (<%= reactive :remaining, 0 %> left)</h1>
...
<!-- Even across multiple places -->
<p>remaining: <%= reactive :remaining, 0 %></p>
```

```ruby
# By adding a single transmit_value line in the channel
def build_graph
  @list = TodoList.new
  transmit_value(:remaining) { @list.remaining }
end
```

`reactive(name, placeholder = "", tag_name: :span)` emits `<span data-hibiki-value="remaining">0</span>`; `transmit_value` wraps the block in an effect that transmits the fresh value whenever a signal the block reads changes, and the client writes it into **every** placeholder carrying that name — like styling by class name, one value may appear any number of times, anywhere on the page (including outside the island, e.g. a header badge). The name joins the two halves and must be page-unique across channels. Each placeholder keeps its own tag, classes, and attributes across updates (only its text changes), so different sites can style the same value differently. In Phlex components, stamp the placeholder yourself by splatting the attributes: `span(**reactive_attrs(:remaining)) { "0" }`.

This is transport- and shape-agnostic: `transmit_value` always uses the channel's own `transmit`, which every `ChannelController` handles — so it works the same whether the page runs the generic controller (the todos example above) or a `ChannelController` subclass, and it composes with a page whose other fragments ride Turbo broadcasts (the core
repo's spike counter proves exactly that — `#count` over broadcast, a `doubled` value over transmit, on one channel). A subclass that overrides `received` should call `super` (or handle the `value` message itself) to keep reactive values live.

Cost and caveats: this is cheap — it rides the island's existing subscription and controller (no new Stimulus instance, no new channel), adding just one server-side effect and a tiny payload per value. Values are text, never markup — the client assigns `textContent`, so nothing is interpreted as HTML; for markup, use a fragment. And when several values always change together, one partial/component fragment beats N spans.

The `data-hibiki-*` attributes the helpers emit are a private contract with the vendored JS — they version together; don't hand-write them in app code. The protocol itself is Stimulus-free (Stimulus only hosts the controller lifecycle), so a hand-rolled client can drive the same attributes: `toy-phlex/` in the core [hibiki](https://github.com/planetaska/hibiki) repo does it in ~40 lines. The helper interface's shape is inspired by [phlex-reactive](https://phlex-reactive.zoolutions.llc)'s `on(...)` actions.

## Usage

```ruby
class CounterChannel < ApplicationCable::Channel
  include Hibiki::Rails::Channel

  # Runs once on the graph's own thread, inside Hibiki.root.
  def build_graph
    @count = Hibiki::State.new(0)
    @step  = Hibiki::State.new(1)
    doubled = Hibiki::Derived.new { @count.value * 2 }

    Hibiki::Effect.new do
      broadcast_replace target: "count", partial: "counter/count",
                        locals: { count: @count.value, doubled: doubled.value }
    end
    Hibiki::Effect.new do
      broadcast_replace target: "step", partial: "counter/step",
                        locals: { step: @step.value }
    end
  end

  # Actions are plain methods that touch signals directly: each one runs
  # on the graph thread inside one Hibiki.batch, so N writes still mean
  # one re-run per affected effect.
  def increment = @count.value += @step.value
  def burst     = 10.times { @count.value += 1 }
end
```

The page supplies a per-page-load graph id (`cid`) and listens on the matching stream:

```erb
<div data-controller="counter" data-counter-cid-value="<%= @cid %>">
  <%= turbo_stream_from "counter", @cid %>
  <%= render "count", count: 0, doubled: 0 %>  <%# placeholder, see below %>
  ...
</div>
```

with `@cid = SecureRandom.uuid` in the controller action. The channel broadcasts to `[channel_name, cid]` — override `stream_name` (and/or `cid`) to derive identity differently.

## What the concern does

- `subscribed` — rejects without a `cid` param, then runs `build_graph`
  inside `Hibiki.root` on a dedicated worker thread (a `GraphActor`).
  ActionCable dispatches on a thread pool with no per-channel ordering;
  hibiki's threading model is confinement — so cable threads only enqueue,
  and the graph lives on exactly one thread.
- every action — the whole body is posted to that thread wrapped in one
  `Hibiki.batch`. `rescue_from` still applies (it runs on the graph
  thread); what it doesn't handle goes to `Rails.error` (source
  `"hibiki_rails"`).
- `unsubscribed` — disposes the root (running `on_cleanup` hooks) and
  stops the worker, draining what was already queued.
- dev reloading — an Engine hook disposes every live graph before code
  reloads (stale effects would run old class versions forever); cable
  clients auto-reconnect and rebuild. Graph state resets on reload, like
  any remount.

## Broadcast helpers

Available inside effects (all bound to `stream_name`):

- `broadcast_replace(target:, **rendering)` — `partial:`/`locals:`,
  `html:`, or anything Turbo's renderer accepts.
- `broadcast_morph(target:, **rendering)` — replace via Turbo 8 morphing
  (keeps focus/scroll).
- `broadcast_refresh` — tell the page to refresh itself.
- `broadcast_refresh_effect(wait: 0.25) { ...read signals... }` — the
  morph-everything style: tracks whatever the block reads and answers
  changes with a debounced refresh, one per burst of actions rather than
  one per action.

## The packaged client

The gem vendors its own JavaScript, turbo-rails-style: the engine puts
`hibiki.js` on the app's asset path and merges the `"hibiki-rails"` pin into the
import map, so importmap-rails apps have no install step beyond
registering the controller — `bin/rails g hibiki:rails:install` does it
(plus the `Helpers` include below, the `ApplicationCable` boilerplate,
and the `@rails/actioncable` pin — a stock app has neither until its
first `rails g channel`), or create the one-line shim yourself:

```js
// app/javascript/controllers/hibiki_controller.js
export { default } from "hibiki-rails" // registers as "hibiki" — the helpers hardcode that identifier
```

The registration is a file-backed shim on purpose: importmap apps
eager-load it from the controllers directory, jsbundling apps get the
matching import/register pair in `controllers/index.js` (the install
generator appends it), and because it is derived from a real controller
file, `bin/rails stimulus:manifest:update` regenerates it instead of
dropping it.

(jsbundling/vite apps: `npm install hibiki-rails` — the [npm
package](https://www.npmjs.com/package/hibiki-rails) is the same module the
engine vendors, and pulls in `@rails/actioncable`; release in lockstep with
the gem.)

| `hibiki_rails` gem | `hibiki-rails` npm | notes |
| ------------------ | ------------------ | ----- |
| 0.1.0              | 0.1.0              | initial release |

The client is one generic Stimulus controller that drives any *island*: a
DOM subtree bound to one channel subscription. Islands are stamped with
the opt-in `Hibiki::Rails::Helpers` — include it where you want the bare
names (`ApplicationHelper` for ERB, individual Phlex components); the gem
never includes it for you:

```erb
<%= tag.div(**hibiki_island(TodosChannel, cid: @cid)) do %>
  <%= render TodoList.new %>  <%# placeholder; replaced by DOM id %>
  <%= tag.form(**on(:add, event: :submit)) do %>
    <input type="text" name="title">
    <button>add</button>
  <% end %>
<% end %>
```

- `hibiki_island(channel, cid:)` — the island root: one subscription,
  identified by the page's `cid`.
- `on(action, event:, with:)` — forward a DOM event (`:click` default,
  `:change`, `:submit`) as a channel action, with `with:` as its payload.
  A changed control also sends `{ name => value }`; a submitted form sends
  its FormData and is reset after performing.
- `reactive(name, placeholder)` / `reactive_attrs(name)` — placeholder for
  a single reactive value, paired with the channel's `transmit_value` (see
  "Reactive values" below).

Transport is the channel's own subscription in both directions: render
effects call `transmit({ html: })` and the client swaps each fragment in
by its root DOM id (`Hibiki::Phlex.render_effect` pairs naturally):

```ruby
def build_graph
  @list = TodoList.new
  Hibiki::Phlex.render_effect(@list) { |html| transmit({ html: }) }
end
```

Because the client registers its `received` callback at subscribe time —
before the server ever runs `build_graph` — the effects' first transmits
always land: no Turbo stream, no connected-wait, and the server-rendered
initial HTML is only a paint-avoidance placeholder. One rule carries over
from any replace-fragment design: never transmit a fragment containing
the input the user is currently typing in.



## The initial-state pattern (Turbo transport)

Islands on the Turbo-broadcast transport instead (the "Usage" example
above) have an ordering problem the transmit transport doesn't: the
graph's effects do their first run inside `subscribed` — usually before
the page's `turbo_stream_from` subscription has confirmed — so the first
broadcast would be lost. Fix the ordering on the client with the packaged
`streamConnected` helper: wait for Turbo to stamp the `connected`
attribute on the stream source, then subscribe the graph channel.

```js
// in the Stimulus controller driving the channel
import { streamConnected } from "hibiki-rails"

async connect() {
  this.consumer = createConsumer()
  await streamConnected(this.element.querySelector("turbo-cable-stream-source"))
  this.subscription = this.consumer.subscriptions.create(
    { channel: "CounterChannel", cid: this.cidValue }, {}
  )
}
```

With that in place the server-rendered initial HTML is only a
paint-avoidance placeholder — the first broadcast always lands and
replaces it, so it doesn't have to match the graph's initial state.

## Error handling layers

1. `rescue_from` on the channel — handles action errors, on the graph
   thread.
2. `Hibiki.error_handler = ->(error, effect) { ... }` — app-level routing
   for effect errors raised during a flush (the gem does not set this).
3. The graph worker's per-job rescue — everything unhandled lands in
   `Rails.error.report(..., source: "hibiki_rails")`. Override per channel
   via `build_graph_actor` and `GraphActor.new(on_error:)`.

## Development

```
bundle exec rake   # specs + rubocop (same as CI)
```

The spec suite boots a minimal inline Rails app (`spec/support/dummy_app.rb`);
the live end-to-end proof app is `spike/` in the core
[hibiki](https://github.com/planetaska/hibiki) repo.
