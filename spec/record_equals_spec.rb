# frozen_string_literal: true

require "rails_helper"
require_relative "support/todo_model"

RSpec.describe "Hibiki::Rails.record_equals" do
  subject(:comparator) { Hibiki::Rails.record_equals }

  before { Todo.delete_all }

  def stale_and_fresh
    todo = Todo.create!(title: "before")
    stale = Todo.find(todo.id)
    todo.update!(title: "after")
    [stale, Todo.find(todo.id)]
  end

  it "treats two loads of the same unchanged row as equal (no-op requery, no repaint)" do
    todo = Todo.create!(title: "same")
    expect(comparator.call(Todo.find(todo.id), Todo.find(todo.id))).to be(true)
  end

  it "sees through AR id-equality when attributes moved" do
    stale, fresh = stale_and_fresh
    expect(stale == fresh).to be(true) # the lie this comparator exists for
    expect(comparator.call(stale, fresh)).to be(false)
  end

  it "distinguishes classes even with equal attributes" do
    a = Data.define(:attributes).new(attributes: { "id" => 1 })
    b = Struct.new(:attributes).new({ "id" => 1 })
    expect(comparator.call(a, b)).to be(false)
  end

  it "is duck-typed — anything answering #attributes compares structurally" do
    shape = Data.define(:attributes)
    expect(comparator.call(shape.new(attributes: { "x" => 1 }), shape.new(attributes: { "x" => 1 }))).to be(true)
    expect(comparator.call(shape.new(attributes: { "x" => 1 }), shape.new(attributes: { "x" => 2 }))).to be(false)
  end

  describe "arrays" do
    it "compares pairwise" do
      todo = Todo.create!(title: "same")
      expect(comparator.call([Todo.find(todo.id)], [Todo.find(todo.id)])).to be(true)
    end

    it "is false when any element's attributes differ" do
      stale, fresh = stale_and_fresh
      expect(comparator.call([stale], [fresh])).to be(false)
    end

    it "is false on size mismatch" do
      todo = Todo.create!(title: "one")
      expect(comparator.call([todo], [])).to be(false)
    end

    it "treats empty arrays as equal" do
      expect(comparator.call([], [])).to be(true)
    end
  end

  describe "fallthrough to ==" do
    it("for plain values") { expect(comparator.call(1, 1)).to be(true) }
    it("for nil, nil") { expect(comparator.call(nil, nil)).to be(true) }

    it "for nil against a record, both ways" do
      todo = Todo.create!(title: "t")
      expect(comparator.call(nil, todo)).to be(false)
      expect(comparator.call(todo, nil)).to be(false)
    end
  end

  it "is memoized" do
    expect(Hibiki::Rails.record_equals).to equal(Hibiki::Rails.record_equals)
  end

  describe "through both core equality gates" do
    it "reruns an effect for an attribute change the default gate would swallow" do
      stale, fresh = stale_and_fresh
      runs = 0

      Hibiki.root do
        sig = Hibiki::State.new(stale, equals: comparator)
        Hibiki::Effect.new do
          sig.value
          runs += 1
        end
        sig.value = fresh
      end

      expect(runs).to eq(2)
    end

    it "(contrast) the default gate swallows the same write" do
      stale, fresh = stale_and_fresh
      runs = 0

      Hibiki.root do
        sig = Hibiki::State.new(stale)
        Hibiki::Effect.new do
          sig.value
          runs += 1
        end
        sig.value = fresh
      end

      expect(runs).to eq(1)
    end
  end
end
