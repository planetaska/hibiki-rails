# frozen_string_literal: true

require "rails_helper"
require_relative "support/todo_model"

RSpec.describe Hibiki::Rails::ReactiveForm do
  # One form class for both the create and the update path — the
  # `form_with model:` convention the macro is built around.
  let(:form_class) do
    Class.new do
      include Hibiki::Rails::ReactiveForm

      reactive_attributes Todo, :title, :done, :priority

      derived(:title_error) { "can't be blank" if title.to_s.strip.empty? }

      def self.name = "TodoForm"
    end
  end

  before { Todo.delete_all }

  describe "generated attributes" do
    let(:form) { form_class.from(Todo.new(title: "milk")) }

    it "reads and writes through signals" do
      expect(form.title).to eq("milk")
      form.title = "bread"
      expect(form.title).to eq("bread")
    end

    it "recomputes deriveds over an attribute on write" do
      expect(form.title_error).to be_nil
      form.title = "  "
      expect(form.title_error).to eq("can't be blank")
    end

    it "does not notify when an equal value is written" do
      runs = 0
      effect = Hibiki::Effect.new { runs += 1 if form.title }
      expect { form.title = "milk" }.not_to(change { runs })
      form.title = "bread"
      expect(runs).to eq(2)
      effect.dispose
    end

    it "exposes the declared attributes as a hash" do
      expect(form.to_h).to eq(title: "milk", done: false, priority: 1)
    end
  end

  # Channel action params arrive as strings; this is the bug the coercion
  # decision exists to prevent.
  describe "wire-type coercion" do
    let(:form) { form_class.from(Todo.new) }

    it "casts booleans through the model's attribute type" do
      form.done = "false"
      expect(form.done).to be(false)
      form.done = "1"
      expect(form.done).to be(true)
      form.done = "0"
      expect(form.done).to be(false)
    end

    it "casts integers" do
      form.priority = "3"
      expect(form.priority).to eq(3)
    end

    it "treats a cast-equal write as a no-op" do
      runs = 0
      effect = Hibiki::Effect.new { runs += 1 if form.priority }
      expect { form.priority = "1" }.not_to(change { runs })
      effect.dispose
    end
  end

  describe "the update path" do
    let(:record) { Todo.create!(title: "milk", priority: 2) }
    let(:form) { form_class.from(record) }

    it "hydrates from the record" do
      expect(form.to_h).to eq(title: "milk", done: false, priority: 2)
      expect(form).to be_persisted
      expect(form.record).to eq(record)
    end

    it "is dirty only after a write" do
      expect(form).not_to be_dirty
      form.title = "bread"
      expect(form).to be_dirty
    end

    it "writes the record and clears dirty on commit" do
      form.title = "bread"
      form.done = "1"
      expect(form.commit).to be(true)
      expect(record.reload.attributes.values_at("title", "done")).to eq(["bread", true])
      expect(form).not_to be_dirty
    end
  end

  describe "the create path (same form class)" do
    let(:form) { form_class.from(Todo.new) }

    it "hydrates the column defaults" do
      expect(form.to_h).to eq(title: nil, done: false, priority: 1)
      expect(form).not_to be_persisted
      expect(form).not_to be_dirty
    end

    it "is dirty once it diverges from the defaults" do
      form.title = "milk"
      expect(form).to be_dirty
    end

    it "inserts on commit and flips persisted?" do
      form.title = "milk"
      expect { form.commit }.to change(Todo, :count).by(1)
      expect(form).to be_persisted
      expect(form).not_to be_dirty
      expect(Todo.last.title).to eq("milk")
    end

    it "re-hydrates from the record after a successful commit" do
      form.title = "milk"
      form.priority = "0" # invalid, so fix it below — see the errors specs
      form.priority = "5"
      form.commit
      expect(form.record.id).not_to be_nil
      expect(form.to_h).to eq(title: "milk", done: false, priority: 5)
    end
  end

  describe "a failed commit" do
    let(:form) { form_class.from(Todo.new) }

    it "returns false, leaves the record unsaved, and mirrors the model's errors" do
      expect(form.commit).to be(false)
      expect(Todo.count).to eq(0)
      expect(form.errors[:title]).to eq(["can't be blank"])
      expect(form.error_for(:title)).to eq("can't be blank")
    end

    it "mirrors every failing validation, not just the first field" do
      form.priority = "0"
      form.commit
      expect(form.errors.keys).to contain_exactly(:title, :priority)
    end

    it "clears the errors on the next successful commit" do
      form.commit
      form.title = "milk"
      expect(form.commit).to be(true)
      expect(form.errors).to be_empty
    end

    it "repaints an effect reading error_for" do
      messages = []
      effect = Hibiki::Effect.new { messages << form.error_for(:title) }
      expect { form.commit }.to change { messages.last }.from(nil).to("can't be blank")
      effect.dispose
    end

    it "raises from commit!, having mirrored the errors first" do
      expect { form.commit! }.to raise_error(ActiveRecord::RecordInvalid)
      expect(form.error_for(:title)).to eq("can't be blank")
    end

    it "commit! returns true when the record is valid" do
      form.title = "milk"
      expect(form.commit!).to be(true)
    end
  end

  describe "#hydrate" do
    let(:record) { Todo.create!(title: "milk") }
    let(:form) { form_class.from(record) }

    # The AR-== trap: signals hold casted scalars rather than the record,
    # so a re-hydrate compares structurally and notifies. Pinned because
    # holding the record in a signal instead would silently not.
    it "notifies when a reloaded record's attributes changed underneath" do
      seen = []
      effect = Hibiki::Effect.new { seen << form.title }
      Todo.find(record.id).update!(title: "bread")
      form.hydrate(record.reload)
      expect(seen).to eq(%w[milk bread])
      effect.dispose
    end

    it "resets dirty and errors" do
      form.title = ""
      form.commit
      expect(form).to be_dirty
      expect(form.errors).not_to be_empty
      form.hydrate(record.reload)
      expect(form).not_to be_dirty
      expect(form.errors).to be_empty
    end

    it "coalesces the per-attribute writes into one effect run" do
      runs = 0
      effect = Hibiki::Effect.new { runs += 1 if form.to_h }
      Todo.find(record.id).update!(title: "bread", priority: 7)
      expect { form.hydrate(record.reload) }.to change { runs }.by(1)
      effect.dispose
    end
  end

  describe "reactive_association" do
    let(:labeled_form_class) do
      Class.new do
        include Hibiki::Rails::ReactiveForm

        reactive_attributes Todo, :title
        reactive_association :labels

        def self.name = "LabeledTodoForm"
      end
    end

    let(:red) { Label.create!(name: "red") }
    let(:blue) { Label.create!(name: "blue") }

    before do
      Labeling.delete_all
      Label.delete_all
    end

    it "hydrates the ids signal from the association's ids reader" do
      record = Todo.create!(title: "milk", labels: [red, blue])
      form = labeled_form_class.from(record)
      expect(form.label_ids).to eq([red.id, blue.id])
      expect(form.to_h).to eq(title: "milk", label_ids: [red.id, blue.id])
    end

    # Channel params arrive as strings; the ids cast goes through the TARGET
    # model's primary-key type, not the form model's columns.
    it "casts wire strings and drops the hidden-input blank" do
      form = labeled_form_class.from(Todo.new)
      form.label_ids = ["", red.id.to_s, blue.id.to_s]
      expect(form.label_ids).to eq([red.id, blue.id])
    end

    it "casts a nil write to an empty selection" do
      form = labeled_form_class.from(Todo.new(labels: [red]))
      form.label_ids = nil
      expect(form.label_ids).to eq([])
    end

    # The dirty? regression the cast exists for: an identity cast would hold
    # ["1"] against a snapshot of [1] and report dirty forever.
    it "treats a cast-equal write as a no-op, so dirty? can settle" do
      record = Todo.create!(title: "milk", labels: [red])
      form = labeled_form_class.from(record)
      expect(form).not_to be_dirty
      form.label_ids = [red.id.to_s]
      expect(form).not_to be_dirty
      form.label_ids = [red.id.to_s, blue.id.to_s]
      expect(form).to be_dirty
      form.label_ids = [red.id.to_s]
      expect(form).not_to be_dirty
    end

    it "creates and removes join rows on commit" do
      record = Todo.create!(title: "milk", labels: [red])
      form = labeled_form_class.from(record)
      form.label_ids = [blue.id.to_s]
      expect(form.commit).to be(true)
      expect(record.reload.labels).to eq([blue])
      expect(Labeling.count).to eq(1)
      expect(form).not_to be_dirty
    end

    it "commits ids on the create path" do
      form = labeled_form_class.from(Todo.new)
      form.title = "milk"
      form.label_ids = [red.id.to_s]
      expect { form.commit }.to change(Todo, :count).by(1)
      expect(Todo.last.labels).to eq([red])
    end

    it "raises a clear error for an association the model does not have" do
      klass = Class.new do
        include Hibiki::Rails::ReactiveForm

        reactive_attributes Todo, :title
        reactive_association :stickers
      end
      form = klass.new
      expect { form.sticker_ids = ["1"] }.to raise_error(/no stickers association/)
    end

    it "raises a clear error when declared before reactive_attributes" do
      expect do
        Class.new do
          include Hibiki::Rails::ReactiveForm

          reactive_association :labels
        end
      end.to raise_error(/reactive_attributes/)
    end
  end

  describe "the model declaration" do
    it "resolves a String or Symbol lazily, so reloading can't pin a stale class" do
      klass = Class.new do
        include Hibiki::Rails::ReactiveForm

        reactive_attributes "Todo", :title, :done
      end
      form = klass.from(Todo.new)
      form.done = "1"
      expect(form.done).to be(true)
      expect(klass.hibiki_model).to be(Todo)
    end

    it "is inherited by subclasses" do
      subclass = Class.new(form_class)
      form = subclass.from(Todo.new(title: "milk"))
      form.priority = "4"
      expect(form.to_h).to eq(title: "milk", done: false, priority: 4)
    end

    it "raises a clear error when a form declares nothing" do
      klass = Class.new { include Hibiki::Rails::ReactiveForm }
      expect { klass.hibiki_model }.to raise_error(/no reactive_attributes declaration/)
    end
  end

  it "raises a clear error when committing without a record" do
    expect { form_class.new.commit }.to raise_error(/no record/)
  end
end
