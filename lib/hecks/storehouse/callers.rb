module Hecks
  module Storehouse
    # The checks on who is calling and what a call may carry: its options, summary, source and
    # role. Extended onto `Storehouse`.
    module Callers
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
      # source,
      # and a role to go with an actor.
      # :nodoc:
      def validate_caller_fields!(request)
        require_summary!(request.summary)
        valid_source!(request.source)
        valid_caller!(request.role, request.actor_id)
      end

      # Required on dispatch/query/state: what makes an audit row legible later.
      # :nodoc:
      def require_summary!(summary)
        return unless summary.nil? || summary.to_s.strip.empty?

        raise Runtime::TypeMismatch,
              "a one-line summary: is required on dispatch/query/state — it is what makes an audit row legible later"
      end

      # :nodoc:
      def valid_source!(source)
        return if source.nil? || SOURCE_TAGS.include?(source.to_s)

        raise Runtime::TypeMismatch, "source: #{source.inspect} is not one of #{SOURCE_TAGS.join(", ")}"
      end

      # actor_id without role would silently bind nothing rather than a real
      # caller — refusing here beats a caller thinking it identified itself.
      # :nodoc:
      def valid_caller!(role, actor_id)
        return unless actor_id && role.nil?

        raise Runtime::TypeMismatch, "actor_id: requires role: too — a caller names WHO through WHICH role they hold"
      end

      # Binds role/actor_id for the block's duration via Hecks.as_caller; role: nil
      # runs the block unbound (query's own authorization does not depend on it).
      # :nodoc:
      def with_caller(role, actor_id, &block)
        return block.call if role.nil?

        Hecks.as_caller(role: role, actor_id: actor_id, &block)
      end

      # A caller who omits role: would otherwise reach a role-gated command
      # unchecked (refuse_role_mismatch no-ops with no bound caller) — refuse here instead.
      # :nodoc:
      def require_caller_for_role_gated!(spec, role)
        return unless spec[:role_gated] && role.nil?

        raise Runtime::Unauthorized,
              "#{spec[:command]} requires role: #{spec[:role].inspect} — this command is role-gated and no caller " \
              "(role:/actor_id:) is bound; dispatching it unbound is refused, not silently unchecked"
      end
    end
  end
end
