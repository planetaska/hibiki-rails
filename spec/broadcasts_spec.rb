# frozen_string_literal: true

require "rails_helper"

# A channel fixture proving the helpers arrive via `include
# Hibiki::Rails::Channel` and bind to the channel's stream.
class BroadcastTestChannel < ActionCable::Channel::Base
  include Hibiki::Rails::Channel

  def build_graph
    @name = Hibiki::State.new("hibiki")
    Hibiki::Effect.new do
      broadcast_replace target: "greeting", partial: "harness/greeting",
                        locals: { name: @name.value }
    end
  end

  def rename(data) = @name.value = data["name"]
end

# Fixture for the debounced Morph-everything style.
class RefreshTestChannel < ActionCable::Channel::Base
  include Hibiki::Rails::Channel

  def build_graph
    @items = Hibiki::State.new(0)
    broadcast_refresh_effect(wait: 0.05) { @items.value }
  end

  def bump = @items.value += 1
end

RSpec.describe Hibiki::Rails::Broadcasts do
  # The helpers are private on purpose (channel action-method safety);
  # this harness exposes them for direct assertions.
  let(:harness) do
    Class.new do
      include Hibiki::Rails::Broadcasts

      public :broadcast_replace, :broadcast_morph, :broadcast_refresh

      def self.name = "BcChannel"
      def stream_name = %w[bc c1]
      def params = { cid: "c1" }
    end.new
  end

  describe "#broadcast_replace" do
    it "broadcasts a replace stream targeting the dom id, rendering a partial" do
      expect { harness.broadcast_replace(target: "greeting", partial: "harness/greeting", locals: { name: "aska" }) }
        .to have_broadcasted_to("bc:c1").with(
          a_string_including('action="replace"')
            .and(including('target="greeting"'))
            .and(including("Hello, aska"))
        )
    end

    it "accepts pre-rendered html" do
      expect { harness.broadcast_replace(target: "greeting", html: "<p>done</p>") }
        .to have_broadcasted_to("bc:c1").with(a_string_including("<p>done</p>"))
    end
  end

  describe "#broadcast_morph" do
    it "broadcasts a replace stream with method=morph (Turbo 8 morphing)" do
      expect { harness.broadcast_morph(target: "greeting", html: "<p>morphed</p>") }
        .to have_broadcasted_to("bc:c1").with(
          a_string_including('action="replace"').and(including('method="morph"'))
        )
    end
  end

  describe "#broadcast_refresh" do
    it "broadcasts a refresh stream" do
      expect { harness.broadcast_refresh }
        .to have_broadcasted_to("bc:c1").with(a_string_including('action="refresh"'))
    end
  end

  # Action Cable does not keep a stream's broadcasts in order, so each render
  # says where it falls and the client applies them by number.
  describe "the render stamp" do
    def stamp(seq) = a_string_including(%(data-hibiki-seq="#{seq}")).and(including('data-hibiki-from="BcChannel/c1"'))

    it "numbers replace and morph renders from 1, in the order sent" do
      sent = ->(matcher) { have_broadcasted_to("bc:c1").with(matcher) }
      first = sent[stamp(1).and(including("<p>1</p>"))]
      second = sent[stamp(2).and(including("<p>2</p>")).and(including('method="morph"'))]
      third = sent[stamp(3).and(including("<p>3</p>"))]

      expect do
        harness.broadcast_replace(target: "a", html: "<p>1</p>")
        harness.broadcast_morph(target: "b", html: "<p>2</p>")
        harness.broadcast_replace(target: "a", html: "<p>3</p>")
      end.to first.and(second).and(third)
    end

    it "keeps the caller's own stream attributes beside it" do
      kept = stamp(1).and(including('data-note="mine"')).and(including('method="morph"'))

      expect { harness.broadcast_morph(target: "a", html: "<p>x</p>", attributes: { "data-note": "mine" }) }
        .to have_broadcasted_to("bc:c1").with(kept)
    end

    it "leaves a refresh unstamped, and uncounted" do
      expect { harness.broadcast_refresh }
        .to have_broadcasted_to("bc:c1").with(satisfy { |stream| !stream.include?("data-hibiki-seq") })
      expect { harness.broadcast_replace(target: "a", html: "<p>x</p>") }
        .to have_broadcasted_to("bc:c1").with(stamp(1))
    end
  end
end

RSpec.shared_context "with an actor drain barrier" do
  def drain
    actor = subscription.instance_variable_get(:@__hibiki_actor)
    barrier = Queue.new
    actor.post { barrier << true }
    raise "graph actor did not drain within 2s" unless barrier.pop(timeout: 2)
  end
end

RSpec.describe BroadcastTestChannel, type: :channel do
  include_context "with an actor drain barrier"

  it "gives channels the helpers, bound to [channel_name, cid]" do
    expect do
      subscribe(cid: "c9")
      drain
      perform :rename, name: "world"
      drain
    end.to have_broadcasted_to("broadcast_test:c9")
      .with(a_string_including("Hello, hibiki"))
      .and have_broadcasted_to("broadcast_test:c9").with(a_string_including("Hello, world"))
  end

  it "stamps renders with its own class and cid, each subscription counting apart" do
    expect do
      subscribe(cid: "c9")
      drain
      perform :rename, name: "world"
      drain
    end.to have_broadcasted_to("broadcast_test:c9")
      .with(a_string_including('data-hibiki-seq="1"').and(including('data-hibiki-from="BroadcastTestChannel/c9"')))
      .and have_broadcasted_to("broadcast_test:c9").with(a_string_including('data-hibiki-seq="2"'))

    unsubscribe
    expect do
      subscribe(cid: "c10")
      drain
    end.to have_broadcasted_to("broadcast_test:c10")
      .with(a_string_including('data-hibiki-seq="1"').and(including('data-hibiki-from="BroadcastTestChannel/c10"')))
  end
end

RSpec.describe RefreshTestChannel, type: :channel do
  include_context "with an actor drain barrier"

  it "answers a burst of actions with ONE debounced refresh" do
    subscribe(cid: "c1")
    drain # the initial (dependency-collecting) run broadcasts right away

    expect do
      3.times { perform :bump } # three flushes, one armed window
      drain
      sleep 0.1 # let the 0.05s window elapse
      drain
    end.to have_broadcasted_to("refresh_test:c1")
      .with(a_string_including('action="refresh"')).once
  end
end
