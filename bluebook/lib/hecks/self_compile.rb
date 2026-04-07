# Hecks::SelfCompile
#
# Self-compile manifest: lists ALL Hecks chapters in load order,
# proving the Bluebook covers 100% of the framework. In Stage 0
# the bootstrap kernel loads via require_relative; in Stage 1
# every file — including the kernel — loads via chapter dispatch.
#
#   Hecks::SelfCompile.chapters         # => [Bootstrap, Bluebook, ...]
#   Hecks::SelfCompile.chapter_names    # => ["Bootstrap", "Bluebook", ...]
#   Hecks::SelfCompile.total_aggregates # => 700+
#
module Hecks
  module SelfCompile
    # Load order matters: Bootstrap bootstraps everything, Bluebook defines
    # the DSL, Runtime wires it, Binding holds it together, then the
    # rest load in dependency order.
    #
    # Chapter names as symbols — resolved lazily so this file can load
    # before all chapter gems are required.
    CHAPTER_NAMES = %i[
      Bootstrap
      Bluebook
      Runtime
      Binding
      Cli
      Templating
      Extensions
      Spec
      Hecksagon
      Persist
      Workshop
      AI
      Rails
      Targets
      HecksAppeal
      Watchers
      Examples
    ].freeze

    # Resolves chapter name symbols to module references.
    # Only includes chapters that are actually loaded.
    def self.chapters
      CHAPTER_NAMES.filter_map do |name|
        next unless Chapters.const_defined?(name)
        mod = Chapters.const_get(name)
        mod if mod.respond_to?(:definition)
      end
    end

    def self.chapter_names
      chapters.map { |ch| ch.definition.name }
    end

    def self.total_aggregates
      chapters.sum { |ch| ch.definition.aggregates.size }
    end

    def self.total_commands
      chapters.sum { |ch|
        ch.definition.aggregates.sum { |a| a.commands.size }
      }
    end

    # Returns a hash of chapter_name => aggregate_count for inspection.
    #
    #   Hecks::SelfCompile.summary
    #   # => {"Bootstrap"=>21, "Bluebook"=>115, ...}
    #
    def self.summary
      chapters.each_with_object({}) do |ch, h|
        d = ch.definition
        h[d.name] = d.aggregates.size
      end
    end

    # Reports chapters declared in the manifest but not yet loaded.
    def self.missing_chapters
      CHAPTER_NAMES.reject { |name| Chapters.const_defined?(name) }
    end
  end
end
