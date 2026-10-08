# frozen_string_literal: true

require_relative "../../bluebook/synthesizer"

module Hecks
  module Projections
    module Site
      # The commands of a project that declare a role, and the verdict on a host's answer to each
      # sent with well-formed arguments but no role and no actor. It sends nothing: the caller
      # dispatches each command and hands the answer back.
      #
      # The arguments are synthesized from the declaration, because a host checks that arguments are
      # present and well-typed before it checks who is calling. A host that enforces roles refuses
      # such a caller as `Unauthorized`. Any other answer (an accepted command, or a refusal for
      # another reason) means the role did not stop it.
      class RoleProbe
        # One command that declares a role.
        #
        # @!attribute [r] verb
        #   @return [String] the command as a host is asked to run it, `Chapter::Aggregate.Command`
        # @!attribute [r] role
        #   @return [String] the role the command declares
        # @!attribute [r] arguments
        #   @return [Hash] one synthesized value per declared attribute
        Check = Struct.new(:verb, :role, :arguments, keyword_init: true)

        # The refusal kind a host enforcing roles answers a caller of the wrong role with.
        REFUSAL = "Unauthorized"

        # The refusal kinds of an argument the host would not build, before it asks who is calling.
        ARGUMENT_REFUSALS = %w[AbsentArgument TypeMismatch InvariantViolation].freeze

        # @param registry [Runtime::Registry] the registry a project booted into
        # @return [Array<Check>] every command that declares a role, in the order declared
        def self.checks(registry)
          registry.bluebooks.values.flat_map do |chapter|
            chapter.aggregates.flat_map do |aggregate|
              aggregate.commands.select(&:role).map { |command| check_for(chapter, aggregate, command) }
            end
          end
        end

        # @return [Check] the check for one command that declares a role
        def self.check_for(chapter, aggregate, command)
          Check.new(verb: "#{chapter.name}::#{aggregate.hecks_name}.#{command.hecks_name}", role: command.role,
                    arguments: Bluebook::Synthesizer.args_for(chapter, aggregate, command))
        end

        # Whether the host refused the synthesized arguments themselves, so the role gate was never
        # reached and the check proves nothing either way.
        #
        # @param answer [Hash] the host's parsed JSON answer
        # @return [Boolean] true when every refusal is an argument refusal
        def self.unchecked?(answer)
          kinds = Array(answer["refusals"]).map { |refusal| refusal["kind"] }
          kinds.any? && (kinds - ARGUMENT_REFUSALS).empty?
        end

        # Judges a host's answer to one check.
        #
        # @param check [Check] the command that was dispatched with no role and no actor
        # @param answer [Hash] the host's parsed JSON answer
        # @return [String, nil] why the answer is wrong, or nil when the host refused the caller
        def self.verdict(check, answer)
          refusals = Array(answer["refusals"])
          return nil if refusals.any? { |refusal| refusal["kind"] == REFUSAL }
          return "was refused, but not as #{REFUSAL}: #{refusals.map { |refusal| refusal["kind"] }.join(", ")}" if refusals.any?

          "was not refused for its role (#{check.role}); is the host running with HECKS_ROLE_ENFORCEMENT=enforce?"
        end
      end
    end
  end
end
