# Tokenizer (no dependencies)
require_relative "bluebook/tokenizer"

# Domain model IR namespace modules (declare autoloads for IR node classes)
require_relative "hecks/domain_model/behavior"
require_relative "hecks/domain_model/structure"
require_relative "hecks/domain_model/names"

# DSL builders (loaded in dependency order, before grammar so HANDLE_METHODS
# can be derived from AggregateBuilder introspection)
require_relative "hecks/dsl/describable"
require_relative "hecks/dsl/attribute_collector"
require_relative "hecks/dsl/event_builder"
require_relative "hecks/dsl/command_builder"
require_relative "hecks/dsl/value_object_builder"
require_relative "hecks/dsl/entity_builder"
require_relative "hecks/dsl/policy_builder"
require_relative "hecks/dsl/lifecycle_builder"
require_relative "hecks/dsl/read_model_builder"
require_relative "hecks/dsl/service_builder"
require_relative "hecks/dsl/workflow_builder"
require_relative "hecks/dsl/aggregate_builder"
require_relative "hecks/dsl/aggregate_rebuilder"
require_relative "hecks/dsl/domain_builder"
require_relative "hecks/dsl/bluebook_builder"

# Grammar (after DSL so HANDLE_METHODS can introspect AggregateBuilder)
require_relative "bluebook/grammar"

# Domain tools
require_relative "hecks/domain/inspector"
require_relative "hecks/domain/builder_methods"
require_relative "hecks/domain/compiler"
require_relative "hecks/domain/in_memory_loader"
require_relative "hecks/domain/ast_extractor"
require_relative "hecks/domain/event_storm_importer"
require_relative "hecks/domain/visualizer_methods"

# Generators (parent namespace files with autoloads, then built-in registrations)
require_relative "hecks/generators/registry"
require_relative "hecks/generators/domain"
require_relative "hecks/generators/infrastructure"
require_relative "hecks/generators/built_in"

# BlueBook
#
# The domain command language for Hecks. Named for Evans' DDD Blue Book
# and Smalltalk's Blue Book — the two traditions this grammar descends from.
#
# Parses domain modeling commands into structured ASTs. No eval — the grammar
# defines what's expressible, and anything outside the grammar is rejected.
#
#   ast = BlueBook::Grammar.parse("Pizza.attr :name, String")
#   # => { target: "Pizza", method: "attr", args: [:name], kwargs: {}, type_args: [String] }
#
module Hecks
  module Chapters
    # Require all paragraph files in a chapter's subdirectory.
    # Call this at the top of a chapter file to eagerly load paragraphs.
    #
    # Convention: chapter file at `chapters/foo.rb`, paragraphs in `chapters/foo/*.rb`.
    #
    #   # At the top of chapters/runtime.rb:
    #   Chapters.require_paragraphs(__FILE__)
    #
    def self.require_paragraphs(chapter_file)
      paragraph_dir = chapter_file.sub(/\.rb$/, "")
      return unless File.directory?(paragraph_dir)
      Dir.glob(File.join(paragraph_dir, "*.rb")).sort.each { |f| require f }
    end

    # Call .define(builder) on each paragraph module in the chapter.
    # Call this inside a chapter's .definition method after defining inline aggregates.
    #
    #   Chapters.define_paragraphs(Runtime, builder)
    #
    def self.define_paragraphs(chapter_module, builder)
      chapter_module.constants.each do |const|
        mod = chapter_module.const_get(const)
        mod.define(builder) if mod.respond_to?(:define)
      end
    end
  end
end

module BlueBook
  VERSION = "2026.03.29.1"

  def self.register!
    Hecks.register_grammar(:bluebook) do |g|
      g.parser = BlueBook::Grammar
      g.builder = Hecks::DSL::DomainBuilder
      g.entry_point = :domain
      g.bare_commands = BlueBook::Grammar::BARE_COMMANDS
      g.handle_methods = BlueBook::Grammar::HANDLE_METHODS
      g.type_map = BlueBook::Grammar::TYPE_MAP
    end
  end
end
