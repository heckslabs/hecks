require_relative "../../../runtime/value"

module Hecks
  module Adapters
    module Driving
      module CliRunner
        # The launcher line a resume dispatches for one stage: the stage's command, then what the
        # saga saved, written the way a person would type it. A saga saves the arguments it
        # started with as typed values, and its stages do not all take the same ones, so the line
        # carries each saved argument the command declares, as its bare value, and names the run
        # as the receiver of a command that acts on a record already made.
        class ResumeLine
          # The key a one-field value is held under once it is plain data.
          SOLE_FIELD = "value".freeze

          # @param bluebook [#aggregates] the bluebook that declares the command
          # @param verb [String] the stage's command, as `Aggregate.Command`
          def initialize(bluebook, verb)
            @verb = verb
            @command = declared(bluebook, *verb.split(".", 2))
          end

          # @param run [String] the saga's run, the receiver of a command on an existing record
          # @param saved [Hash] the arguments the saga started with
          # @return [Array<String>] the bang line, word by word
          def words(run, saved)
            receiver = @command && !@command.creates? ? ["to=#{run}"] : []
            ["#{@verb}!", *receiver, *taken(saved).filter_map { |name, value| word(name, value) }]
          end

          private

          # A command no bluebook declares is handed everything, so its own refusal names the fault.
          def taken(saved)
            return saved unless @command

            names = @command.attributes.map { |attribute| attribute.name.to_sym }
            saved.select { |name, _value| names.include?(name.to_sym) }
          end

          def word(name, value)
            plain = bare(Runtime::Value.materialize_unwrapped(value))
            "#{name}=#{plain}" unless plain.nil?
          end

          # A saga read back from a store holds a one-field value as a Hash with the key `value`.
          def bare(held)
            return held unless held.is_a?(Hash) && held.size == 1 && held.keys.first.to_s == SOLE_FIELD

            held.values.first
          end

          def declared(bluebook, aggregate_name, command_name)
            return unless bluebook.respond_to?(:aggregates)

            aggregate = bluebook.aggregates.find { |candidate| candidate.hecks_name == aggregate_name }
            aggregate&.commands&.find { |candidate| candidate.hecks_name == command_name }
          end
        end
      end
    end
  end
end
