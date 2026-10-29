# frozen_string_literal: true

require "hecks/ci_speed/adapters/local_runner/refused"

module Hecks
  module Adapters
    class LocalRunner
      # The experiments the bluebook knows how to run: its `ExperimentDefinition` rows, each with
      # the `ExperimentStep` rows that name it, in the order they are written.
      class Catalog
        # One step: a hecks verb and the `name=value` words it is called with.
        Step = Struct.new(:name, :verb, :arguments, :needs, keyword_init: true) do
          # @return [Array<String>] the launcher words for the verb: a command ends in `!`, and a
          #   query is asked with `query`
          def form = verb.end_with?("!") ? [verb] : ["query", verb]

          # @return [Array<String>] the verb's own arguments
          def words = arguments.to_s.split

          # @return [Array<String>] the names of the `name=value` arguments, as a usage line
          #   lists them; a flag such as `--help` has no name to look up
          def argument_names = words.reject { |word| word.start_with?("-") }.map { |word| word.split("=").first }
        end

        # One definition: what it times, and what each sample starts from.
        Definition = Struct.new(:name, :measures, :cache_state, :needs_generated_tree, :steps, keyword_init: true) do
          # @return [Boolean] whether each sample starts from a copy of the generated tree
          def generated_tree? = needs_generated_tree == "yes"
        end

        # Reads the rows a bluebook declares.
        #
        # @param bluebook [Bluebook::Declaration] the CiSpeed bluebook
        # @return [Catalog] its definitions
        def self.from_bluebook(bluebook)
          new(definitions_of(rows_of(bluebook, "ExperimentDefinition"), rows_of(bluebook, "ExperimentStep")))
        end

        # @param bluebook [Bluebook::Declaration] a bluebook to search
        # @param object [String] the name of the value object whose rows are wanted
        # @return [Array<Hash{Symbol => String}>] its member rows
        def self.rows_of(bluebook, object)
          value_objects_of(bluebook).select { |candidate| candidate.hecks_name == object }.flat_map(&:members)
        end

        # @param bluebook [Bluebook::Declaration] a bluebook to search
        # @return [Array<Bluebook::ValueObject>] every value object of every aggregate
        def self.value_objects_of(bluebook) = bluebook.aggregates.flat_map(&:value_objects)
        private_class_method :value_objects_of

        # @param definitions [Array<Definition>] the experiments, by their own names
        def initialize(definitions)
          @definitions = definitions.to_h { |definition| [definition.name, definition] }
        end

        # @param name [String] a definition's name
        # @return [Definition] the definition
        # @raise [Refused] when no definition has that name, listing those that do
        def fetch(name)
          @definitions.fetch(name) do
            raise Refused, "no experiment definition is named #{name.inspect}; defined: #{names.join(", ")}"
          end
        end

        # @return [Array<String>] every definition's name
        def names = @definitions.keys

        # @param definitions [Array<Hash>] `ExperimentDefinition` rows
        # @param steps [Array<Hash>] `ExperimentStep` rows
        # @return [Array<Definition>] each definition with the steps that name it
        def self.definitions_of(definitions, steps)
          definitions.map do |row|
            own = steps.select { |step| step[:definition] == row[:name] }
            Definition.new(name: row[:name], measures: row[:measures], cache_state: row[:cache_state],
                           needs_generated_tree: row[:needs_generated_tree], steps: own.map { |step| step_of(step) })
          end
        end
        private_class_method :definitions_of

        # @param row [Hash] an `ExperimentStep` row
        # @return [Step] the step, needing nothing unless the row says so
        def self.step_of(row)
          Step.new(name: row[:name], verb: row[:verb], arguments: row[:arguments], needs: row[:needs] || "none")
        end
        private_class_method :step_of
      end
    end
  end
end
