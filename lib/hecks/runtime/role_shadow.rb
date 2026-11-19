# frozen_string_literal: true

require "json"
require_relative "caller"
require_relative "collecting"
require_relative "refusal_wording"

module Hecks
  module Runtime
    # The Ruby runtime's shadow of the role rule the Rust host enforces: what a command declaring a
    # role would do with a caller that states none, once refusal is on.
    #
    # Ruby refuses no unstated caller in any mode. Under `shadow` a role-gated command dispatched
    # with no caller writes one `would_refuse_role` line to stderr in the Rust host's wording and
    # runs as before: the line means a host in `enforce` would refuse it. A reaction gets the
    # host-internal shape with `origin: "reaction"`; a preview or dry run logs nothing.
    #
    # The mode is installed at boot from the host wiring variable `HECKS_ROLE_ENFORCEMENT` (ADR
    # 0132, read by `Assembly`): `shadow` and `enforce` both mean shadow, since Ruby does not refuse
    # yet; anything else, or unset, is `off`, the mode before any boot.
    module RoleShadow
      # The role an unstated caller is checked as, the Rust host's `ANONYMOUS_ROLE`.
      ANONYMOUS_ROLE = "Anonymous"
      # The words that turn shadow on.
      SHADOW_WORDS = %w[shadow enforce].freeze
      # The process's mode and where its lines go; one write at boot, read by every dispatch.
      SETTINGS = Struct.new(:mode, :sink).new(:off, nil)

      module_function

      # @param value [String, nil] the variable's value
      # @return [Symbol] `:shadow` for `shadow` or `enforce`, `:off` for anything else
      def parse(value) = SHADOW_WORDS.include?(value.to_s.strip.downcase) ? :shadow : :off

      # Fixes the mode for the rest of the process; a boot calls it.
      #
      # @param mode [Symbol] `:shadow` or `:off`
      # @return [Symbol] the mode installed
      def install(mode) = SETTINGS.mode = mode

      # Sends the lines somewhere other than stderr, or back to stderr with nil.
      #
      # @param sink [IO, nil] where lines are written
      # @return [IO, nil] the sink
      def write_to(sink) = SETTINGS.sink = sink

      # @return [Symbol] the installed mode, `:off` before any boot
      def mode = SETTINGS.mode

      # Writes the `would_refuse_role` line for a role-gated command dispatched with no caller, when
      # the mode is shadow and the dispatch is not a validating run.
      #
      # @param command [Bluebook::Command] the command that declares `roles`
      # @param verb [String] the command's fully qualified verb
      # @return [nil]
      def note(command, verb)
        return if mode != :shadow || Collecting.active?

        roles = command.role_set
        write(Caller.reacting? ? reaction_fields(verb, roles) : caller_fields(command, verb, roles))
        nil
      end

      # @return [Hash] the line for an unstated outside caller, as the host's shadow logs it
      def caller_fields(command, verb, roles)
        values = { command: command.hecks_name, role: roles.join(" or "), caller_role: ANONYMOUS_ROLE }
        message = RefusalWording.render_site("Unauthorized", "role_mismatch", **values)
        { verb: verb, role: ANONYMOUS_ROLE, actor_id: nil,
          refusals: [{ kind: "Unauthorized", message: message }] }
      end

      # @return [Hash] the line for a reaction, the host's `origin: host_internal` shape
      def reaction_fields(verb, roles)
        { verb: verb, origin: "reaction", role: nil, actor_id: nil, roles: roles }
      end

      # One JSON object on one line, `level` and `msg` first, as the host's log renders it.
      def write(fields)
        line = JSON.generate({ level: "error", msg: "would_refuse_role" }.merge(fields))
        (SETTINGS.sink || $stderr).puts(line)
      end
    end
  end
end
