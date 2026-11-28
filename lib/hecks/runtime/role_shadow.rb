# frozen_string_literal: true

require "json"
require_relative "caller"
require_relative "collecting"
require_relative "refusal_wording"

module Hecks
  module Runtime
    # The role mode of the Ruby runtime, the same `HECKS_ROLE_ENFORCEMENT` the Rust host reads
    # (ADR 0216), and the shadow log of what `enforce` would refuse.
    #
    # - **enforce** (the default, and any word it does not know): a role-gated or `policy_only`
    #   command refuses the caller who stated no role, and a policy's reaction that declares no
    #   `acts_as` in a cascade a caller began.
    # - **shadow** (the opt-out for a migration): both run, and the first count of a key writes one
    #   `would_refuse_role` line to stderr in the Rust host's wording; a preview logs nothing.
    # - **off**: both run and nothing is written.
    #
    # A caller that states a role is checked the same in every mode. A boot installs the mode
    # from the host wiring variable (ADR 0132, read by `Assembly`).
    module RoleShadow
      # The role an unstated caller is checked as, the Rust host's `ANONYMOUS_ROLE`.
      ANONYMOUS_ROLE = Caller::ANONYMOUS
      # The words that name a mode other than the default.
      WORDS = { "shadow" => :shadow, "off" => :off }.freeze
      # The mode before any boot and for any word `WORDS` lacks.
      DEFAULT = :enforce
      # The process's mode and where its lines go; one write at boot, read by every dispatch.
      SETTINGS = Struct.new(:mode, :sink).new(DEFAULT, nil)

      module_function

      # @param value [String, nil] the variable's value
      # @return [Symbol] `:shadow` or `:off` for those words, `:enforce` for anything else
      def parse(value) = WORDS.fetch(value.to_s.strip.downcase, DEFAULT)

      # Fixes the mode for the rest of the process; a boot calls it.
      #
      # @param mode [Symbol] `:enforce`, `:shadow` or `:off`
      # @return [Symbol] the mode installed
      def install(mode) = SETTINGS.mode = mode

      # Sends the lines somewhere other than stderr, or back to stderr with nil.
      #
      # @param sink [IO, nil] where lines are written
      # @return [IO, nil] the sink
      def write_to(sink) = SETTINGS.sink = sink

      # @return [Symbol] the installed mode, `:enforce` before any boot
      def mode = SETTINGS.mode

      # @return [Boolean] whether the unstated caller is refused
      def enforcing? = mode == :enforce

      # The word a kernel step carries for the mode, as the Rust host writes it; nil under
      # `enforce`, which the kernel assumes.
      #
      # @return [String, nil] `shadow`, `off` or nil
      def step_word = enforcing? ? nil : mode.to_s

      # The one spelling of a fully qualified verb, shared by the shadow line and the report.
      #
      # @param domain [String] the command's domain
      # @param names [Array<String, nil>] the aggregate, entity and command names; nils are skipped
      # @return [String] `Domain::Aggregate.Command`, `Domain::Aggregate.Entity.Command`, or
      #   `Domain::Command` when no aggregate is known
      def verb_for(domain, *names) = "#{domain}::#{names.compact.join(".")}"

      # Writes the `would_refuse_role` line for a role-gated command dispatched with no stated
      # caller, when the mode is shadow and the dispatch is not a validating run.
      #
      # @param command [Bluebook::Command] the command that declares `roles`
      # @param verb [String] the command's fully qualified verb
      # @return [nil]
      def note(command, verb)
        return if mode != :shadow || Collecting.active?

        roles = command.role_set
        write(Caller.unstated? ? caller_fields(command, verb, roles) : internal_fields(verb, roles))
        nil
      end

      # @return [Hash] the line for an unstated outside caller, as the host's shadow logs it
      def caller_fields(command, verb, roles)
        values = { command: command.hecks_name, role: roles.join(" or ") }
        message = RefusalWording.render_site("Unauthorized", "role_unstated", **values)
        { verb: verb, role: ANONYMOUS_ROLE, actor_id: nil,
          refusals: [{ kind: "Unauthorized", message: message }] }
      end

      # @return [Hash] the line for a reaction or the process's own dispatch, the host's
      #   `origin: host_internal` shape
      def internal_fields(verb, roles)
        { verb: verb, origin: Caller.reacting? ? "reaction" : "internal", role: nil, actor_id: nil, roles: roles }
      end

      # One JSON object on one line, `level` and `msg` first, as the host's log renders it.
      def write(fields)
        line = JSON.generate({ level: "error", msg: "would_refuse_role" }.merge(fields))
        (SETTINGS.sink || $stderr).puts(line)
      end
    end
  end
end
