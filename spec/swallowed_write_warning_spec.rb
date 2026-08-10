# frozen_string_literal: true

require "rails_helper"
require_relative "support/todo_model"

RSpec.describe Hibiki::Rails::SwallowedWriteWarning do
  # Prepended onto a throwaway subclass, never onto Hibiki::State itself —
  # a prepend on the real class would leak into every other example group.
  let(:state_class) { Class.new(Hibiki::State) { prepend Hibiki::Rails::SwallowedWriteWarning } }
  let(:logger) { instance_spy(Logger) }

  before do
    Todo.delete_all
    allow(Rails).to receive(:logger).and_return(logger)
  end

  def stale_and_fresh
    todo = Todo.create!(title: "before")
    stale = Todo.find(todo.id)
    todo.update!(title: "after")
    [stale, Todo.find(todo.id)]
  end

  it "warns when AR id-equality swallows an attribute change, without unswallowing it" do
    stale, fresh = stale_and_fresh
    sig = state_class.new(stale)

    sig.value = fresh

    expect(logger).to have_received(:warn).with(/id-equality|Working with ActiveRecord/)
    # Zero semantic change: the write is still dropped.
    expect(sig.peek).to equal(stale)
  end

  it "warns for an array of records swallowed the same way" do
    stale, fresh = stale_and_fresh
    sig = state_class.new([stale])

    sig.value = [fresh]

    expect(logger).to have_received(:warn)
    expect(sig.peek.first).to equal(stale)
  end

  it "stays silent when the dropped write carried no attribute change" do
    todo = Todo.create!(title: "same")
    sig = state_class.new(todo)

    sig.value = Todo.find(todo.id)

    expect(logger).not_to have_received(:warn)
  end

  it "stays silent when the write goes through" do
    first = Todo.create!(title: "one")
    second = Todo.create!(title: "two")
    sig = state_class.new(first)

    sig.value = second

    expect(logger).not_to have_received(:warn)
    expect(sig.peek).to equal(second)
  end

  it "stays silent when a custom comparator changed the gate" do
    stale, fresh = stale_and_fresh
    sig = state_class.new(stale, equals: Hibiki::Rails.record_equals)

    sig.value = fresh

    expect(logger).not_to have_received(:warn)
    # record_equals sees the attribute change, so the write goes through.
    expect(sig.peek).to equal(fresh)
  end

  it "stays silent for plain values" do
    sig = state_class.new(1)
    sig.value = 1

    expect(logger).not_to have_received(:warn)
  end

  describe "installation" do
    it "registers a dev-only engine initializer" do
      names = Hibiki::Rails::Engine.initializers.map(&:name)
      expect(names).to include("hibiki_rails.swallowed_write_warning")
    end

    it "is not prepended outside development (the dummy app booted in test)" do
      expect(Hibiki::State.ancestors).not_to include(described_class)
    end
  end
end
