# frozen_string_literal: true

require_relative "table/rows"
require_relative "table/checks"

module Hecks
  module Projections
    module CiPipeline
      # A client's workflow rows, read from its bluebook and checked against the CiPipeline
      # bluebook's vocabulary.
      #
      # The rows are the `member` lines of the value objects `Workflow`, `Trigger`, `Secret`,
      # `Job`, `Need`, `Output`, `Env`, `Step` and `StepInput` in any bluebook of the project (the
      # CiPipeline bluebook's Workflow, JobSpec and Step aggregates name the fields and the closed
      # sets). This class joins them by workflow and job name into one tree and refuses a table that
      # contradicts itself, naming every problem at once, each on the row it concerns.
      class Table
        # A table the projection refuses; the message lists each problem on its own line.
        class Invalid < ArgumentError; end

        # The name of the chapter that declares the shape of a row.
        CHAPTER = "CiPipeline"

        # The value object whose member rows mark a bluebook as the client's.
        MARKER = "Workflow"

        # @return [Array<Tree::Workflow>] the workflows, in the order the client declared them
        attr_reader :workflows

        # Finds the one bluebook of a project that declares workflow rows.
        #
        # @param registry [Runtime::Registry] the registry the project booted into
        # @return [Bluebook::Chapter] the bluebook holding `Workflow` rows
        # @raise [Invalid] when no bluebook, or more than one, declares one
        def self.chapter(registry)
          claimed = holders(registry)
          raise Invalid, "no chapter declares a value_object \"#{MARKER}\" with member rows" if claimed.empty?
          return claimed.first if claimed.one?

          raise Invalid, "#{claimed.size} chapters declare a value_object \"#{MARKER}\": " \
                         "#{claimed.map(&:name).join(", ")}; a project has one set of workflow rows"
        end

        # @return [Array<Bluebook::Chapter>] the project's bluebooks that declare `Workflow` rows
        def self.holders(registry)
          clients = registry.bluebooks.values.reject { |chapter| chapter.name == CHAPTER }
          clients.select { |chapter| rows_of(chapter, MARKER).any? }
        end

        # Reads and checks one bluebook's workflow rows.
        #
        # @param chapter [Bluebook::Chapter] the bluebook that declares the rows
        # @param registry [Runtime::Registry] the registry the project booted into, which holds the
        #   CiPipeline bluebook
        # @return [Table] the checked table
        # @raise [Invalid] when the CiPipeline bluebook is not attached or a row is refused
        def self.read(chapter, registry:)
          rows = Typing::SHAPES.keys.to_h { |object| [object, rows_of(chapter, object)] }
          new(rows, vocabulary: vocabulary(registry))
        end

        # @param registry [Runtime::Registry] a registry holding the CiPipeline bluebook
        # @return [Hash{Symbol => Object}] `:trigger` and `:uses`, the closed sets, as arrays of
        #   members, and `:patterns`, each named field to the regexp its chapter value object holds
        # @raise [Invalid] when the registry does not hold the CiPipeline bluebook
        def self.vocabulary(registry)
          pipeline = registry.bluebook(CHAPTER) or
            raise Invalid, "the project does not attach the #{CHAPTER} chapter (attaches \"#{CHAPTER}\")"
          { trigger:  members(pipeline, "Workflow", "Trigger"),
            uses:     members(pipeline, "JobSpec", "ActionRef").reject(&:empty?),
            patterns: Rows::PATTERNS.transform_values { |(aggregate, object)| pattern(pipeline, aggregate, object) } }
        end

        # @param chapter [Bluebook::Chapter] a bluebook to search
        # @param object [String] the name of the value object whose rows are wanted
        # @return [Array<Hash{Symbol => Object}>] the member rows of its value objects of that name
        def self.rows_of(chapter, object)
          objects = chapter.aggregates.flat_map(&:value_objects)
          objects.select { |candidate| candidate.hecks_name == object }.flat_map(&:members)
        end

        # @return [Array<String>] the members of a closed set held as a value object of an aggregate
        def self.members(chapter, aggregate, object)
          held(chapter, aggregate, object).members.map { |member| member.fetch(:value) }
        end

        # @return [Regexp] the pattern of a value object's one attribute
        def self.pattern(chapter, aggregate, object)
          Regexp.new(held(chapter, aggregate, object).attributes.first.pattern)
        end

        # @return [Bluebook::ValueObject] a value object of an aggregate of the chapter
        def self.held(chapter, aggregate, object)
          chapter.aggregate(aggregate).value_objects.find { |candidate| candidate.hecks_name == object }
        end
        private_class_method :holders, :members, :pattern, :held

        # @param rows [Hash{String => Array<Hash{Symbol => Object}>}] each object's declared rows
        # @param vocabulary [Hash{Symbol => Object}] the closed sets and patterns
        # @raise [Invalid] when a row is refused
        def initialize(rows, vocabulary:)
          problems = []
          @workflows = Rows.new(rows, vocabulary, problems).workflows
          Checks.new(@workflows, vocabulary, problems).call
          return if problems.empty?

          raise Invalid, "the workflow rows are refused:\n#{problems.map { |line| "  - #{line}" }.join("\n")}"
        end
      end
    end
  end
end
