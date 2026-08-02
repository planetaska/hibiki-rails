# frozen_string_literal: true

# The models the scaffold generators introspect.
#
# ScaffoldSchema has two builders — one reads a parsed `field:type` argument
# list, the other reads a real schema — and only the second needs a database.
# The harness runs the generator in-process, so `destination_root` decides
# where files are WRITTEN while the model constant and its columns come from
# here. That is what makes the introspection path testable without an app
# checkout.
#
# Deliberately a second pair rather than more columns on Todo: Item's
# belongs_to is required, and reactive_form_spec.rb saves bare Todos.
#
# Shaped as a structural isomorph of the reference app's Author/Book
# (~/rails_projects/hibiki-crud) so the generated output can be compared
# against a hand-written conversion that was measured in a browser:
# one belongs_to, one string, one text, one integer with a default, one date,
# one boolean with a default, plus a presence validator and a numericality
# validator. Every derived list the templates need has at least one member and
# at least one non-member.

ActiveRecord::Migration.verbose = false

ActiveRecord::Schema.define do
  create_table :shelves, force: true do |t|
    t.string :name
    t.boolean :active, default: true, null: false
    t.timestamps
  end

  # Column order here is the order `columns_hash` reports, which is what the
  # introspection builder walks — so this file also pins the emitted order of
  # BookRow's members and reactive_attributes' argument list.
  create_table :items, force: true do |t|
    t.integer :shelf_id, null: false
    t.string :title
    t.text :notes
    t.integer :count, default: 0, null: false
    t.date :due_on
    t.boolean :active, default: false, null: false
    t.timestamps
  end

  # The parent injection's dependent: derivation, in two rows. Both foreign
  # keys are NULLABLE and the associations differ, which is the whole point:
  # dependent: follows the reflection, never the column. With
  # belongs_to_required_by_default a nullable column routinely backs a required
  # belongs_to, and :nullify there leaves rows that fail their own validations.
  create_table :crates, force: true do |t|
    t.integer :shelf_id
    t.string :name
    t.timestamps
  end

  create_table :baskets, force: true do |t|
    t.integer :shelf_id
    t.string :name
    t.timestamps
  end

  # Parent and child are the same file, and `parent` has no plural a generator
  # may invent.
  create_table :categories, force: true do |t|
    t.integer :parent_id
    t.string :name
    t.timestamps
  end

  # A polymorphic belongs_to, whose two columns are BOTH ignored — so an
  # explicit `taggable:references` argument matches nothing and would fall
  # through to the argument's own answer if the merge did not refuse it.
  create_table :tags, force: true do |t|
    t.integer :taggable_id
    t.string :taggable_type
    t.string :label
    t.timestamps
  end

  # Validator SHAPES rather than column types — the options that decide
  # whether a rule can be checked before a round trip at all.
  create_table :gauges, force: true do |t|
    t.integer :reading
    t.integer :peak
    t.string :label
    t.timestamps
  end
end

class Shelf < ActiveRecord::Base
  has_many :items, dependent: :destroy

  validates :name, presence: true
end

class Item < ActiveRecord::Base
  # Required by default (belongs_to_required_by_default), which is the fact
  # the generated live_errors reads to emit "must be selected".
  belongs_to :shelf

  # The label a belongs_to contributes to the row projection — the generator
  # emits this delegate, so a fixture that lacked it would let a broken
  # template pass.
  delegate :name, to: :shelf, prefix: true, allow_nil: true

  validates :title, presence: true
  validates :notes, presence: true
  validates :count, numericality: { greater_than_or_equal_to: 0 }
end

# Nullable shelf_id, REQUIRED association -> dependent: :destroy.
class Crate < ActiveRecord::Base
  belongs_to :shelf
end

# Same column, optional association -> dependent: :nullify. The pair is what
# proves the derivation reads the reflection.
class Basket < ActiveRecord::Base
  belongs_to :shelf, optional: true
end

# The parent file IS the child file, so the ping is already covered by the
# model's own after_commit and only the has_many is owed.
class Category < ActiveRecord::Base
  belongs_to :parent, class_name: "Category", optional: true
end

class Tag < ActiveRecord::Base
  belongs_to :taggable, polymorphic: true
end

# Every validator here is one the generator must NOT copy naively: a blank
# value is legal for the first two, and the last two run only sometimes. All
# four still run at #commit and still land in #errors — the question is only
# what may be asserted before the round trip.
class Gauge < ActiveRecord::Base
  validates :reading, numericality: { greater_than: 0, allow_nil: true }
  validates :peak, numericality: { less_than: 100, allow_blank: true }
  validates :label, presence: true, if: :calibrated?
  validates :label, length: { maximum: 8 }, on: :create

  def calibrated? = true
end
