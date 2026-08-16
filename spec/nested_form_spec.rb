# frozen_string_literal: true

require "rails_helper"
require_relative "support/nested_models"

RSpec.describe Hibiki::Rails::ReactiveForm, "reactive_nested" do
  # A three-level chain (Project -> Task -> Note): every nested behavior
  # below must hold at both depths through the same code — nothing in the
  # module counts levels.
  let(:note_form_class) do
    Class.new do
      include Hibiki::Rails::ReactiveForm

      reactive_attributes Note, :body, :pinned

      def self.name = "NoteForm"
    end
  end

  let(:task_form_class) do
    note_form = note_form_class
    Class.new do
      include Hibiki::Rails::ReactiveForm

      reactive_attributes Task, :name
      reactive_nested :notes, note_form

      def self.name = "TaskForm"
    end
  end

  let(:form_class) do
    task_form = task_form_class
    Class.new do
      include Hibiki::Rails::ReactiveForm

      reactive_attributes Project, :title
      reactive_nested :tasks, task_form

      def self.name = "ProjectForm"
    end
  end

  before do
    Note.delete_all
    Task.delete_all
    Project.delete_all
  end

  describe "the macro" do
    it "registers the association in hibiki_nested" do
      expect(form_class.hibiki_nested).to eq(tasks: task_form_class)
    end

    it "walks the registry up through subclasses" do
      subclass = Class.new(form_class) { def self.name = "SpecialProjectForm" }
      expect(subclass.hibiki_nested).to eq(tasks: task_form_class)
      expect(subclass.hibiki_nested_form(:tasks)).to be(task_form_class)
    end

    it "keeps the nested name out of hibiki_attributes" do
      expect(form_class.hibiki_attributes).to eq([:title])
    end

    it "resolves a String declaration lazily" do
      stub_const("SpecNoteForm", note_form_class)
      klass = Class.new do
        include Hibiki::Rails::ReactiveForm

        reactive_attributes Task, :name
        reactive_nested :notes, "SpecNoteForm"

        def self.name = "StringDeclaredTaskForm"
      end
      expect(klass.hibiki_nested_form(:notes)).to be(note_form_class)
    end
  end

  describe "#hydrate" do
    it "builds child forms in the association's scope order with c-keys" do
      project = Project.create!(title: "album")
      second = project.tasks.create!(name: "mix", position: 2)
      first = project.tasks.create!(name: "record", position: 1)

      form = form_class.from(project)
      expect(form.tasks.map(&:name)).to eq(%w[record mix])
      expect(form.tasks.map(&:nested_key)).to eq(["c#{first.id}", "c#{second.id}"])
    end

    it "gives unpersisted association builds n-keys" do
      project = Project.new(title: "album")
      project.tasks.build(name: "record")
      form = form_class.from(project)
      expect(form.tasks.sole.nested_key).to eq("n1")
    end

    it "recurses into grandchildren" do
      project = Project.create!(title: "album")
      task = project.tasks.create!(name: "record", position: 1)
      note = task.notes.create!(body: "use the good mic")

      form = form_class.from(project)
      grandchild = form.tasks.sole.notes.sole
      expect(grandchild.body).to eq("use the good mic")
      expect(grandchild.nested_key).to eq("c#{note.id}")
    end

    it "rebuilds children and clears marks on re-hydrate" do
      project = Project.create!(title: "album")
      project.tasks.create!(name: "record", position: 1)

      form = form_class.from(project)
      form.nested_remove(:tasks, form.tasks.sole)
      expect(form.tasks.sole).to be_marked_for_destruction

      form.hydrate(project)
      expect(form.tasks.sole).not_to be_marked_for_destruction
      expect(form).not_to be_dirty
    end
  end

  describe "#nested_add / #nested_remove" do
    let(:project) { Project.create!(title: "album") }
    let(:form) { form_class.from(project) }

    it "appends a child hydrated from column defaults and returns it" do
      child = form.nested_add(:tasks)
      expect(form.tasks).to eq([child])
      expect(child.name).to be_nil
      expect(child.persisted?).to be(false)
    end

    it "assigns monotonic n-keys" do
      expect(form.nested_add(:tasks).nested_key).to eq("n1")
      expect(form.nested_add(:tasks).nested_key).to eq("n2")
    end

    it "replaces the array rather than mutating it" do
      runs = 0
      effect = Hibiki::Effect.new { runs += 1 if form.tasks }
      expect { form.nested_add(:tasks) }.to change { runs }.by(1)
      effect.dispose
    end

    it "drops a new child from the array" do
      child = form.nested_add(:tasks)
      form.nested_remove(:tasks, child)
      expect(form.tasks).to eq([])
    end

    it "keeps a persisted child and marks it for destruction" do
      project.tasks.create!(name: "record", position: 1)
      form = form_class.from(project)

      child = form.tasks.sole
      form.nested_remove(:tasks, child)
      expect(form.tasks).to eq([child])
      expect(child).to be_marked_for_destruction
      expect(form.to_h[:tasks_attributes].sole).to include(_destroy: true)
    end
  end

  describe "#to_h and #dirty?" do
    let(:project) { Project.create!(title: "album") }

    it "serializes the tree as recursive *_attributes" do
      task = project.tasks.create!(name: "record", position: 1)
      note = task.notes.create!(body: "good mic")

      form = form_class.from(project)
      expect(form.to_h).to eq(
        title: "album",
        tasks_attributes: [
          { name: "record", id: task.id, _destroy: false,
            notes_attributes: [{ body: "good mic", pinned: false, id: note.id, _destroy: false }] }
        ]
      )
    end

    it "flips dirty? on a child edit, an add, a remove, and a mark — and only then" do
      task = project.tasks.create!(name: "record", position: 1)
      form = form_class.from(project)
      expect(form).not_to be_dirty

      form.tasks.sole.name = "record" # cast-equal write
      expect(form).not_to be_dirty

      form.tasks.sole.name = "master"
      expect(form).to be_dirty

      form.hydrate(project)
      form.nested_add(:tasks)
      expect(form).to be_dirty

      form.hydrate(project)
      form.nested_remove(:tasks, form.tasks.sole)
      expect(form).to be_dirty
      expect(Task.exists?(task.id)).to be(true) # marking touches no row
    end
  end

  describe "#commit on success" do
    it "persists edit + add + destroy at both depths in one save" do
      project = Project.create!(title: "album")
      keep = project.tasks.create!(name: "record", position: 1)
      keep.notes.create!(body: "good mic")
      doomed = project.tasks.create!(name: "scrap", position: 2)

      form = form_class.from(project)
      keep_form = form.tasks.find { it.record.id == keep.id }
      keep_form.name = "master"
      keep_form.notes.sole.body = "the better mic"
      keep_form.nested_add(:notes).body = "new note"
      form.nested_remove(:tasks, form.tasks.find { it.record.id == doomed.id })
      added = form.nested_add(:tasks)
      added.name = "release"

      expect(form.commit).to be(true)

      expect(Task.exists?(doomed.id)).to be(false)
      expect(project.reload.tasks.map(&:name)).to contain_exactly("master", "release")
      expect(keep.reload.notes.map(&:body)).to contain_exactly("the better mic", "new note")
    end

    it "re-hydrates children with fresh c-keys and a clean dirty?" do
      project = Project.create!(title: "album")
      form = form_class.from(project)
      form.nested_add(:tasks).name = "record"

      expect(form.commit).to be(true)
      expect(form.tasks.sole.nested_key).to eq("c#{Task.sole.id}")
      expect(form).not_to be_dirty
    end
  end

  describe "#commit on failure" do
    let(:project) { Project.create!(title: "album") }

    it "lands each child's errors on the right child form" do
      project.tasks.create!(name: "record", position: 1)
      project.tasks.create!(name: "mix", position: 2)

      form = form_class.from(project)
      bad, good = form.tasks
      bad.name = ""

      expect(form.commit).to be(false)
      expect(bad.error_for(:name)).to eq("can't be blank")
      expect(good.error_for(:name)).to be_nil
    end

    it "lands grandchild errors at depth two, on new children too" do
      form = form_class.from(project)
      task = form.nested_add(:tasks)
      task.name = "record"
      task.nested_add(:notes).body = "fine"
      task.nested_add(:notes).body = ""

      expect(form.commit).to be(false)
      fine, blank = task.notes
      expect(blank.error_for(:body)).to eq("can't be blank")
      expect(fine.error_for(:body)).to be_nil
    end

    it "keeps keys and typed values across the failure" do
      form = form_class.from(project)
      child = form.nested_add(:tasks)
      note = child.nested_add(:notes)
      note.pinned = "1"

      expect(form.commit).to be(false)
      expect(form.tasks.sole).to be(child)
      expect(child.nested_key).to eq("n1")
      expect(note.pinned).to be(true)
    end

    it "does not insert duplicate children when a failed commit is retried" do
      form = form_class.from(project)
      form.nested_add(:tasks).name = "record"
      form.title = ""

      expect(form.commit).to be(false)
      expect(form.commit).to be(false) # twice: each failure must stay clean
      form.title = "album"
      expect(form.commit).to be(true)

      expect(Task.where(name: "record").count).to eq(1)
    end
  end

  describe "#commit!" do
    let(:project) { Project.create!(title: "album") }

    it "raises on an invalid child and stays clean for a fixed retry" do
      form = form_class.from(project)
      child = form.nested_add(:tasks)

      expect { form.commit! }.to raise_error(ActiveRecord::RecordInvalid)
      child.name = "record"
      expect(form.commit!).to be(true)
      expect(Task.where(name: "record").count).to eq(1)
    end
  end

  describe "casting" do
    it "casts child writes through the child model's attribute types" do
      form = task_form_class.from(Task.new)
      note = form.nested_add(:notes)
      note.pinned = "0"
      expect(note.pinned).to be(false)
      note.pinned = "1"
      expect(note.pinned).to be(true)
    end
  end
end
