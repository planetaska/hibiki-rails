# frozen_string_literal: true

require "rails/generators"
require "erubi"

# The generators are found by Rails via $LOAD_PATH at runtime; specs load
# them all up front the same way a `bin/rails g` invocation would.
# BEFORE the requires, not after: Base.class_option resolves each option's
# default out of Rails::Generators.options at class-DEFINITION time, so a
# generator required first freezes `orm: false` and its inherited model and
# migration hooks then silently do nothing. `bin/rails g` configures first for
# the same reason; getting this backwards makes the specs assert against half a
# scaffold and notice nothing.
Rails::Generators.configure!(Rails.application.config.generators)

Dir[File.expand_path("../../lib/generators/**/*_generator.rb", __dir__)].each { |file| require file }

module GeneratorHarness
  # Run a generator class against a throwaway destination root, returning
  # everything it printed (say/say_status write to $stdout via Thor's shell,
  # resolved at call time — capturing here is enough).
  #
  # stderr too, because Thor's `start` RESCUES Thor::Error — which
  # Rails::Generators::Error subclasses — and prints it rather than raising.
  # That is right for a CLI (a message, not a backtrace), but it means a
  # generator's refusal is only observable here.
  def run_generator(klass, args = [], destination:)
    out = StringIO.new
    err = StringIO.new
    original_out = $stdout
    original_err = $stderr
    $stdout = out
    $stderr = err
    klass.start(args, destination_root: destination, shell: non_interactive_shell)
    out.string + err.string
  ensure
    $stdout = original_out
    $stderr = original_err
  end

  # An example that generates TWICE into one destination hits Thor's
  # "Overwrite?" prompt, which reads $stdin — and since this harness has
  # already swapped $stdout, the prompt lands in the StringIO and the suite
  # just STOPS with nothing printed. It only stops on a TTY: piped or under
  # CI, $stdin.gets returns nil at EOF and Thor reads that as "yes", so the
  # suite is green everywhere except a developer's terminal. Answer before
  # being asked.
  def non_interactive_shell
    Thor::Base.shell.new.tap { |shell| shell.instance_variable_set(:@always_force, true) }
  end

  # Every emitted view, whichever view layer produced it.
  #
  # The raise is the whole point. Three guards used to glob app/views/**/*.erb,
  # which passes VACUOUSLY against --phlex output — a guard that silently
  # inspects nothing is worse than no guard, because it reads as covered.
  def generated_views(destination)
    paths = Dir[File.join(destination, "app/views/**/*.{erb,rb}")]
    raise "no views were emitted under #{destination}" if paths.empty?

    paths
  end

  # A view's markup with its comments removed — `<%# … %>` on the ERB side and
  # `#` on the Phlex side. Both layers may NAME a data-hibiki attribute in
  # prose; neither may write one.
  def view_markup_without_comments(path)
    source = File.read(path)
    return source.gsub(/<%#.*?%>/m, "") if path.end_with?(".erb")

    source.gsub(/^\s*#.*$/, "")
  end

  # Zeitwerk resolves app/views/admin/books/row_form.rb to
  # Views::Admin::Books::RowForm and raises Zeitwerk::NameError at EAGER LOAD
  # if the file defines anything else — in production, on deploy, not here.
  def expect_zeitwerk_resolvable_views(destination)
    Dir[File.join(destination, "app/views/**/*.rb")].each do |path|
      relative = path.delete_prefix(File.join(destination, "app/views/")).delete_suffix(".rb")
      expected = "Views::#{relative.split('/').map(&:camelize).join('::')}"

      expect(File.read(path)).to include("class #{expected} <"),
                                 "#{path} should define #{expected}"
    end
  end

  # Syntax smoke over everything a generator emitted: compile (never run)
  # each Ruby file directly and each ERB view through ActionView's erubi
  # subclass (plain Erubi::Engine can't parse Rails' `<%= tag.div do %>`
  # block-expression form) — a SyntaxError in any template fails the
  # example.
  def expect_valid_generated_sources(destination)
    Dir[File.join(destination, "**/*.rb")].each do |path|
      RubyVM::InstructionSequence.compile(File.read(path), path)
    end
    Dir[File.join(destination, "**/*.erb")].each do |path|
      src = ActionView::Template::Handlers::ERB::Erubi.new(File.read(path)).src
      RubyVM::InstructionSequence.compile(src, path)
    end
  end
end
