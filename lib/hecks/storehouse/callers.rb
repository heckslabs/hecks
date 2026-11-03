require_relative "../bluebook/expression/evaluator"

module Hecks
  module Storehouse
    # The checks on who is calling and what a call may carry: its options, summary, source and
    # role. Extended onto `Storehouse`.
    module Callers
      # One argument as a value object, the shape the bluebook's givens read (`actor_id.value`).
      Value = Struct.new(:value)

      # Refuses an option a call does not take, as a method without that keyword would.
      #
      # @param options [Hash] the keywords the caller passed
      # @param allowed [Array<Symbol>] the keywords the call takes
      # @raise [ArgumentError] naming the first one not in `allowed`
      # :nodoc:
      def check_options!(options, allowed)
        unknown = options.keys - allowed
        raise ArgumentError, "unknown keyword: #{unknown.first.inspect}" unless unknown.empty?
      end

      # The checks every dispatch and query makes before it reads anything: a summary, a known
      # source, a known surface, and the caller's own givens.
      # :nodoc:
      def validate_caller_fields!(request)
        require_summary!(request.summary)
        valid_source!(request.source)
        valid_surface!(request.surface)
        admit_caller!(request, "no", request.name)
      end

      # A dispatch of a command that is role-gated also needs a caller bound, which only the
      # resolved command says.
      # :nodoc:
      def admit_command!(request, spec)
        admit_caller!(request, spec[:role_gated] ? "yes" : "no", spec[:command])
      end

      # Checks the caller against the givens of Governance's `Call.Admit`, which the bluebook
      # declares: an actor names the role it holds, and a role-gated command has a caller bound.
      # Each given is evaluated here from the bluebook, so no copy of the rule lives in Ruby.
      #
      # @param request [Request] the call; its role and actor_id are the caller's
      # @param role_gated [String] "yes" when the command asked for is role-gated, else "no"
      # @param name [String] the command or question named, for the refusal
      # @return [void]
      # @raise [Runtime::Unauthorized] naming the first given that does not hold
      # :nodoc:
      def admit_caller!(request, role_gated, name)
        attrs = { role_name: Value.new(request.role), actor_id: Value.new(request.actor_id),
                  role_gated: Value.new(role_gated) }
        admit_givens.each do |given|
          next if Bluebook::Expression::Evaluator.call_rule(given, {}, attrs)

          raise Runtime::Unauthorized, "#{name} refused: #{given.description}"
        end
      end

      # The givens of `Call.Admit`, read once from Governance's bluebook.
      # :nodoc:
      def admit_givens
        @admit_givens ||= Framework.command_of("Governance", "Call", "Admit").givens
      end

      # Required on dispatch/query/state: what makes an audit row legible later.
      # :nodoc:
      def require_summary!(summary)
        return unless summary.nil? || summary.to_s.strip.empty?

        raise Runtime::TypeMismatch,
              "a one-line summary: is required on dispatch/query/state — it is what makes an audit row legible later"
      end

      # :nodoc:
      def valid_surface!(surface)
        return if surface.nil? || Storehouse::SURFACES.include?(surface.to_s)

        raise Runtime::TypeMismatch, "surface: #{surface.inspect} is not one of #{Storehouse::SURFACES.join(", ")}"
      end

      # :nodoc:
      def valid_source!(source)
        return if source.nil? || Storehouse::SOURCE_TAGS.include?(source.to_s)

        raise Runtime::TypeMismatch, "source: #{source.inspect} is not one of #{Storehouse::SOURCE_TAGS.join(", ")}"
      end

      # Binds role/actor_id for the block's duration via Hecks.as_caller; role: nil
      # runs the block unbound (query's own authorization does not depend on it).
      # :nodoc:
      def with_caller(role, actor_id, &)
        return yield if role.nil?

        Hecks.as_caller(role: role, actor_id: actor_id, &)
      end
    end
  end
end
