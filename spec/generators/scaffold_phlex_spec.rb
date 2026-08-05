# frozen_string_literal: true

require "rails_helper"
require "support/generator_harness"
require_relative "../support/scaffold_models"

# The --phlex view layer.
#
# Its own file rather than a describe block in the scaffold_controller spec,
# for the same reason the loading state has one: this is a second tree of
# templates, and the assertions that matter are about the SEAM between them —
# what changes, what must not, and what the two trees have to keep agreeing on.
RSpec.describe Hibiki::Rails::Generators::ScaffoldControllerGenerator, "--phlex" do
  include GeneratorHarness

  around do |example|
    Dir.mktmpdir do |dir|
      @destination = dir
      FileUtils.mkdir_p(File.join(dir, "config"))
      File.write(File.join(dir, "config/routes.rb"), "Rails.application.routes.draw do\nend\n")
      example.run
    end
  end

  def generated(path) = File.read(File.join(@destination, path))
  def exists?(path) = File.exist?(File.join(@destination, path))

  def generate(args = [], name: "Item")
    run_generator(described_class, [name, *args], destination: @destination)
  end

  # phlex:install's own artifacts. Generated components inherit Views::Base and
  # are reached by constant, so both have to be there or nothing resolves.
  def phlex_installed
    FileUtils.mkdir_p(File.join(@destination, "app/views"))
    File.write(File.join(@destination, "app/views/base.rb"), "class Views::Base < Components::Base\nend\n")
    FileUtils.mkdir_p(File.join(@destination, "config/initializers"))
    File.write(File.join(@destination, "config/initializers/phlex.rb"), <<~RUBY)
      Rails.autoloaders.main.push_dir("#{@destination}/app/views", namespace: Views)
    RUBY
  end

  describe "the wiring probes" do
    # Warn, never fail: the scaffold may legitimately come before
    # `bundle add phlex-rails`, and writing nothing would leave the user with
    # no output to fix.
    it "warns when phlex-rails is not in the bundle, and still writes the files" do
      output = generate(%w[--phlex])

      expect(output).to include("phlex-rails is not in this bundle")
      expect(exists?("app/channels/items_channel.rb")).to be(true)
    end

    # The one that actually bites. A successful require proves the GEM is
    # present and proves nothing about this app — without base.rb and the
    # autoloader mapping, every page raises NameError at its first request.
    it "warns when phlex:install has not run" do
      expect(generate(%w[--phlex])).to include("phlex:install has not run here")
    end

    it "says nothing about phlex:install once both artifacts are there" do
      phlex_installed

      expect(generate(%w[--phlex])).not_to include("phlex:install has not run")
    end

    # An initializer that pushes app/views without the Views namespace is the
    # half-configured case, and it fails exactly the same way.
    it "is not satisfied by an initializer that does not name the namespace" do
      phlex_installed
      File.write(File.join(@destination, "config/initializers/phlex.rb"), "# nothing\n")

      expect(generate(%w[--phlex])).to include("phlex:install has not run here")
    end

    it "stays quiet about all of it without the flag" do
      output = generate

      expect(output).not_to include("phlex-rails is not in this bundle")
      expect(output).not_to include("phlex:install has not run")
    end
  end
end
