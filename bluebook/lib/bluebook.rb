# = BlueBook
#
# The domain command language for Hecks. Named for Evans' DDD Blue Book
# and Smalltalk's Blue Book — the two traditions this grammar descends from.
#
# Loaded from its own Bluebook chapter — the chapter lists every aggregate,
# and load_aggregates derives the require tree from naming conventions.
# The Bluebook IS the Bluebook.
#
#   ast = BlueBook::Grammar.parse("Pizza.attr :name, String")
#

# Bootstrap: Tokenizer, IR, DSL kernel — the minimum to run BluebookBuilder.
# These must load before any chapter can describe aggregates.
require_relative "bluebook/tokenizer"
require_relative "hecks/domain_model/behavior"
require_relative "hecks/domain_model/structure"
require_relative "hecks/domain_model/names"
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

# Chapter infrastructure (must load before any chapter files)
require_relative "hecks/chapters"

# Load the Bluebook chapter (paragraphs describe all aggregates)
require_relative "hecks/chapters/bluebook"

# Implementation files are loaded by Hecks::Chapters.load_chapter
# after the full framework infrastructure is available.
# See hecksties/lib/hecks.rb for the boot sequence.

module BlueBook
  VERSION = "2026.03.29.1"

  def self.register!
    Hecks.register_grammar(:bluebook) do |g|
      g.parser = BlueBook::Grammar
      g.builder = Hecks::DSL::BluebookBuilder
      g.entry_point = :domain
      g.bare_commands = BlueBook::Grammar::BARE_COMMANDS
      g.handle_methods = BlueBook::Grammar::HANDLE_METHODS
      g.type_map = BlueBook::Grammar::TYPE_MAP
    end
  end
end
