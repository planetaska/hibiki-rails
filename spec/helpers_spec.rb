# frozen_string_literal: true

require "spec_helper"

RSpec.describe Hibiki::Rails::Helpers do
  # The helpers are opt-in instance methods, exactly like Hibiki::DSL.
  let(:view) { Class.new { include Hibiki::Rails::Helpers }.new }

  describe "#hibiki_island" do
    it "stamps the controller, channel, and cid as Stimulus values" do
      expect(view.hibiki_island("CounterChannel", cid: "abc")).to eq(
        { data: { controller: "hibiki",
                  hibiki_channel_value: "CounterChannel",
                  hibiki_cid_value: "abc" } }
      )
    end

    it "accepts the channel class itself" do
      stub_const("TodosChannel", Class.new)
      data = view.hibiki_island(TodosChannel, cid: "abc")[:data]
      expect(data[:hibiki_channel_value]).to eq("TodosChannel")
    end

    it "omits the params attribute when params: is absent" do
      expect(view.hibiki_island("C", cid: "abc")[:data]).not_to have_key(:hibiki_params_value)
    end

    it "serializes extra subscribe params as a JSON value" do
      data = view.hibiki_island("BookChannel", cid: "abc", params: { record_id: 7 })[:data]
      expect(data[:hibiki_params_value]).to eq('{"record_id":7}')
    end
  end

  describe "#on" do
    it "defaults to the click event" do
      expect(view.on(:increment)).to eq({ data: { hibiki_on: "click->increment" } })
    end

    it "encodes the chosen event into the token" do
      expect(view.on(:set_step, event: :change)[:data][:hibiki_on])
        .to eq("change->set_step")
      expect(view.on(:add, event: :submit)[:data][:hibiki_on])
        .to eq("submit->add")
    end

    it "serializes with: as a JSON payload attribute" do
      expect(view.on(:toggle, with: { index: 3 })[:data]).to eq(
        { hibiki_on: "click->toggle", hibiki_with: '{"index":3}' }
      )
    end

    it "omits the payload attribute when with: is absent" do
      expect(view.on(:increment)[:data]).not_to have_key(:hibiki_with)
    end

    describe "an event list" do
      it "emits one token per event, whitespace-separated" do
        expect(view.on(:load_more, event: %i[click visible])[:data][:hibiki_on])
          .to eq("click->load_more visible->load_more")
      end

      it "still emits a single token for a bare Symbol" do
        expect(view.on(:load_more, event: :click)[:data][:hibiki_on])
          .to eq("click->load_more")
      end
    end

    describe "modifiers" do
      it "debounces :input by default so a keystroke is not a round trip" do
        expect(view.on(:search, event: :input)[:data][:hibiki_debounce]).to eq(250)
      end

      it "takes an explicit debounce over the default" do
        expect(view.on(:search, event: :input, debounce: 50)[:data][:hibiki_debounce]).to eq(50)
      end

      it "omits the attribute for debounce: 0 — every keystroke is sent" do
        expect(view.on(:search, event: :input, debounce: 0)[:data])
          .not_to have_key(:hibiki_debounce)
      end

      it "does not debounce other events unless asked" do
        expect(view.on(:set_step, event: :change)[:data]).not_to have_key(:hibiki_debounce)
        expect(view.on(:set_step, event: :change, debounce: 100)[:data][:hibiki_debounce])
          .to eq(100)
      end

      it "carries the confirm message verbatim" do
        expect(view.on(:destroy, confirm: "Are you sure?")[:data][:hibiki_confirm])
          .to eq("Are you sure?")
      end

      it "marks a form as keeping its inputs on reset: false" do
        expect(view.on(:save, event: :submit, reset: false)[:data][:hibiki_reset])
          .to eq("false")
      end

      it "omits the reset attribute for the default and for reset: true" do
        expect(view.on(:add, event: :submit)[:data]).not_to have_key(:hibiki_reset)
        expect(view.on(:add, event: :submit, reset: true)[:data]).not_to have_key(:hibiki_reset)
      end

      it "marks a control's native behavior as its fallback" do
        expect(view.on(:new_form, fallback: true)[:data][:hibiki_fallback]).to eq("true")
      end

      it "omits the fallback attribute for the default and for fallback: false" do
        expect(view.on(:new_form)[:data]).not_to have_key(:hibiki_fallback)
        expect(view.on(:new_form, fallback: false)[:data]).not_to have_key(:hibiki_fallback)
      end
    end

    # The attribute is a whitespace-separated token list, so a name carrying
    # a space or an arrow silently changes what the client dispatches.
    describe "name validation" do
      it "rejects an event name outside the allowlist" do
        expect { view.on(:x, event: "click->evil other") }
          .to raise_error(ArgumentError, /event or action/)
      end

      it "rejects an action name outside the allowlist" do
        expect { view.on("bad action") }.to raise_error(ArgumentError, /event or action/)
      end

      it "allows a dotted event qualifier" do
        expect(view.on(:submit_now, event: :"keydown.enter")[:data][:hibiki_on])
          .to eq("keydown.enter->submit_now")
      end
    end

    describe "key events" do
      it "emits a key combination in canonical form" do
        expect(view.on(:save, event: "keydown.meta+ctrl+s")[:data][:hibiki_on])
          .to eq("keydown.ctrl+meta+s->save")
      end

      it "emits a window-scoped key beside another event" do
        expect(view.on(:new_row, event: ["click", "keydown.n@window"])[:data][:hibiki_on])
          .to eq("click->new_row keydown.n@window->new_row")
      end

      it "adds no debounce" do
        expect(view.on(:cancel, event: "keydown.esc")[:data]).not_to have_key(:hibiki_debounce)
      end

      it "rejects a bare keydown" do
        expect { view.on(:x, event: :keydown) }.to raise_error(ArgumentError, /names no key/)
      end

      it "rejects an unknown key, alt, and shift with a digit" do
        expect { view.on(:x, event: "keydown.f1") }.to raise_error(ArgumentError, /key "f1"/)
        expect { view.on(:x, event: "keydown.alt+s") }.to raise_error(ArgumentError, /modifier "alt"/)
        expect { view.on(:x, event: "keydown.shift+1") }.to raise_error(ArgumentError, /shift/)
      end

      it "rejects a scope on any other event" do
        expect { view.on(:x, event: "click@window") }
          .to raise_error(ArgumentError, /only a keydown/)
      end

      it "leaves an event that merely starts with keydown to the name check" do
        expect(view.on(:x, event: "keydown-ish")[:data][:hibiki_on]).to eq("keydown-ish->x")
      end
    end
  end

  describe "#reactive" do
    it "paints a span placeholder carrying the value name" do
      expect(view.reactive(:doubled, 0))
        .to eq('<span data-hibiki-value="doubled">0</span>')
    end

    it "defaults to an empty placeholder" do
      expect(view.reactive(:doubled)).to eq('<span data-hibiki-value="doubled"></span>')
    end

    it "escapes the placeholder — values are text, not markup" do
      expect(view.reactive(:msg, "<b>hi</b>"))
        .to eq('<span data-hibiki-value="msg">&lt;b&gt;hi&lt;/b&gt;</span>')
    end

    it "accepts an alternate tag name" do
      expect(view.reactive(:step, 1, tag_name: :strong))
        .to eq('<strong data-hibiki-value="step">1</strong>')
    end

    it "rejects a name outside the allowlist" do
      expect { view.reactive("bad name") }.to raise_error(ArgumentError, /name/)
    end

    it "rejects a tag name outside the allowlist" do
      expect { view.reactive(:x, 0, tag_name: "sp an") }
        .to raise_error(ArgumentError, /tag/)
    end
  end

  describe "#reactive_attrs" do
    it "exposes the placeholder attributes for hand-stamped sites (Phlex)" do
      expect(view.reactive_attrs(:doubled))
        .to eq({ data: { hibiki_value: "doubled" } })
    end

    it "rejects a name outside the allowlist" do
      expect { view.reactive_attrs("bad name") }.to raise_error(ArgumentError, /name/)
    end
  end

  describe "#props" do
    it "stamps the wanted DOM properties as JSON" do
      expect(view.props(indeterminate: true))
        .to eq({ data: { hibiki_props: '{"indeterminate":true}' } })
    end

    # Under a morph the element survives, so an omitted false would leave
    # the property stuck at true.
    it "emits a false boolean rather than omitting it" do
      expect(view.props(indeterminate: false)[:data][:hibiki_props])
        .to eq('{"indeterminate":false}')
    end

    it "coerces a boolean property from truthiness" do
      expect(view.props(indeterminate: nil)[:data][:hibiki_props])
        .to eq('{"indeterminate":false}')
      expect(view.props(indeterminate: "some")[:data][:hibiki_props])
        .to eq('{"indeterminate":true}')
    end

    it "spells a property by its DOM name on the wire" do
      expect(view.props(scroll_top: 0, scroll_left: 12.5)[:data][:hibiki_props])
        .to eq('{"scrollTop":0,"scrollLeft":12.5}')
    end

    it "omits a nil number" do
      expect(view.props(scroll_top: nil, indeterminate: true)[:data][:hibiki_props])
        .to eq('{"indeterminate":true}')
    end

    it "stamps nothing when no property is left" do
      expect(view.props(scroll_top: nil)).to eq({ data: {} })
    end

    it "carries key: so the attribute text changes when the key does" do
      expect(view.props(scroll_top: 0, key: ["jazz", 2])[:data][:hibiki_props])
        .to eq('{"scrollTop":0,"key":["jazz",2]}')
    end

    it "rejects a property outside the allowlist, naming the allowed ones" do
      expect { view.props(inner_html: "<b>") }
        .to raise_error(ArgumentError, /inner_html.*indeterminate, scroll_top, scroll_left/)
    end

    it "rejects a number that is not one" do
      expect { view.props(scroll_top: "12") }.to raise_error(ArgumentError, /scroll_top/)
      expect { view.props(scroll_top: Float::NAN) }.to raise_error(ArgumentError, /scroll_top/)
      expect { view.props(scroll_top: Float::INFINITY) }.to raise_error(ArgumentError, /scroll_top/)
    end
  end

  describe "#focus" do
    it "stamps the focus mark" do
      expect(view.focus).to eq({ data: { hibiki_focus: "true" } })
    end

    it "asks for the text to be selected" do
      expect(view.focus(select: true)).to eq({ data: { hibiki_focus: "select" } })
    end

    # Never the autofocus attribute: Turbo acts on it inside a stream, on
    # renders the visitor did not cause.
    it "emits nothing but its own data key" do
      expect(view.focus(select: true).keys).to eq([:data])
      expect(view.focus[:data].keys).to eq([:hibiki_focus])
    end

    it "merges with #on on one element" do
      expect(view.on(:set_field, event: :input).deep_merge(view.focus)[:data])
        .to include(hibiki_on: "input->set_field", hibiki_focus: "true")
    end
  end
end
