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
# These must load before any chapter can describe aggregates, so they
# cannot use chapter-driven loading. They define the types and builders
# that BluebookBuilder.new("tmp") needs inside every chapter .define method.
require "bluebook/tokenizer"
require "hecks/bluebook_model/behavior"
require "hecks/bluebook_model/structure"
require "hecks/bluebook_model/names"
require "hecks/dsl/describable"
require "hecks/dsl/attribute_collector"
require "hecks/dsl/event_builder"
require "hecks/dsl/command_builder"
require "hecks/dsl/value_object_builder"
require "hecks/dsl/entity_builder"
require "hecks/dsl/policy_builder"
require "hecks/dsl/lifecycle_builder"
require "hecks/dsl/read_model_builder"
require "hecks/dsl/service_builder"
require "hecks/dsl/workflow_builder"
require "hecks/dsl/aggregate_builder"
require "hecks/dsl/aggregate_rebuilder"
require "hecks/dsl/bluebook_builder"
require "hecks/dsl/bluebook_builder"

# Chapter infrastructure (must load before any chapter files)
require "hecks/chapters"

# Load the Bluebook chapter (paragraphs describe all aggregates)
require "hecks/chapters/bluebook"

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
