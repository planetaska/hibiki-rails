# frozen_string_literal: true

# The record ReactiveForm's specs hydrate from and commit to. Real
# ActiveRecord on the dummy app's in-memory sqlite: the macro's contract is
# AR's own (type_for_attribute casting, update on an unpersisted record,
# errors after a failed save), so a duck-typed fake would only spec itself.

ActiveRecord::Migration.verbose = false

ActiveRecord::Schema.define do
  create_table :todos, force: true do |t|
    t.string :title
    t.boolean :done, default: false, null: false
    t.integer :priority, default: 1, null: false
  end

  # The has_many :through pair reactive_association's specs go through.
  # Label, not Tag — scaffold_models.rb owns Tag, and the full suite loads
  # both files into one namespace and one schema.
  create_table :labels, force: true do |t|
    t.string :name
  end

  create_table :labelings, force: true do |t|
    t.references :todo, null: false
    t.references :label, null: false
  end
end

class Todo < ActiveRecord::Base
  has_many :labelings, dependent: :destroy
  has_many :labels, through: :labelings

  validates :title, presence: true
  validates :priority, numericality: { greater_than: 0 }
end

class Label < ActiveRecord::Base
end

class Labeling < ActiveRecord::Base
  belongs_to :todo
  belongs_to :label
end
