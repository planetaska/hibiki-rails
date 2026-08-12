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
  # reactive_attributes' argument list.
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

  # §5.15, in four shapes: a unique index nothing mirrors, a unique index the
  # model does validate, a COMPOSITE unique index, and a plain non-unique one
  # that must never produce a notice.
  create_table :badges, force: true do |t|
    t.string :slug
    t.string :code
    t.string :season
    t.integer :number
    t.string :sortable
    t.timestamps
  end

  add_index :badges, :slug, unique: true
  add_index :badges, :code, unique: true
  add_index :badges, %i[season number], unique: true
  add_index :badges, :sortable

  # Validator SHAPES rather than column types — the options that decide
  # whether a rule can be checked before a round trip at all.
  create_table :gauges, force: true do |t|
    t.integer :reading
    t.integer :peak
    t.string :label
    t.timestamps
  end

  # hibiki:rails:multiselect, in its three join situations. Part/Fitting is
  # "join model exists, association not declared" (and Part doubles as the
  # target when the generator must CREATE a join — any unused name works).
  # Sticker/ItemSticker is "has_many :through already declared", where the
  # join argument is redundant. NOT :labels — todo_model.rb owns that table,
  # and the full suite loads both files into one schema.
  create_table :parts, force: true do |t|
    t.string :name
    t.timestamps
  end

  create_table :fittings, force: true do |t|
    t.integer :item_id, null: false
    t.integer :part_id, null: false
    t.timestamps
  end

  create_table :stickers, force: true do |t|
    t.string :caption
    t.timestamps
  end

  create_table :item_stickers, force: true do |t|
    t.integer :item_id, null: false
    t.integer :sticker_id, null: false
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

  # The multiselect's "association already declared" path — the join argument
  # is redundant here and read off this reflection. :parts is deliberately NOT
  # declared: that is the injection path.
  has_many :item_stickers, dependent: :destroy
  has_many :stickers, through: :item_stickers

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

# `slug` and the season/number pair are the unmirrored ones. `code` is
# validated, so the generator has nothing to say about it — a notice that fires
# anyway is noise, and noise is what gets post-install output ignored.
class Badge < ActiveRecord::Base
  validates :code, uniqueness: true
end

# The multiselect's target and join fixtures. Part#name hits the
# LABEL_CANDIDATES inference; Sticker's only string column is caption, which
# exercises the first-string-column fallback.
class Part < ActiveRecord::Base
end

# The "join exists" path: correct belongs_to pair, deliberately NO touch: —
# the generator injects it.
class Fitting < ActiveRecord::Base
  belongs_to :item
  belongs_to :part
end

class Sticker < ActiveRecord::Base
end

class ItemSticker < ActiveRecord::Base
  belongs_to :item, touch: true
  belongs_to :sticker
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
