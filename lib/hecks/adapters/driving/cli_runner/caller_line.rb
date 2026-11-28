# frozen_string_literal: true

require_relative "../../../runtime/caller"

module Hecks
  module Adapters
    module Driving
      module CliRunner
        # The caller a command line dispatches as (ADR 0216). `--as <Role>` (or `--as=<Role>`)
        # states the role; without it, a caller an enclosing block already bound stays; without
        # either, the launched bluebook's `launcher` setting may list `caller_roles`, the roles
        # whoever runs this launcher holds, and the line takes the first one the command
        # declares. A line that states none of these is the unstated caller, which a role-gated
        # command refuses.
        module CallerLine
          # The flag that states the caller's role.
          FLAG = "--as"
          # The flag with its role in the same word.
          JOINED = /\A--as=(?<role>.+)\z/
          # The line a bare `--as` answers.
          MISSING = "hecks: --as needs a role, as in --as Maintainer"

          # Takes `--as` and its role out of a line.
          #
          # @param argv [Array<String>] the words the launcher was given
          # @return [Array(String, Array<String>), Array(Symbol, Array<String>)] the stated role
          #   (nil when none) and the words without the flag, or `:missing` when no role follows
          #   `--as` (nothing, another flag, or a `path=value` pair)
          def split_caller(argv)
            at = argv.index { |word| word == FLAG || JOINED.match?(word) }
            return [nil, argv] unless at

            joined = JOINED.match(argv[at])
            role = joined ? joined[:role] : argv[at + 1]
            return [:missing, argv] unless role_word?(role)

            [role, argv[0...at] + argv[(at + (joined ? 1 : 2))..]]
          end

          # Whether a word after `--as` names a role: not nothing, another flag or a pair.
          #
          # @api private
          # @return [Boolean]
          def role_word?(word) = !word.nil? && !word.start_with?("-") && !word.include?("=")

          # Runs the block as the line's caller.
          #
          # @param runtime [Runtime::Dispatcher] the booted domain
          # @param spec [Hash, nil] the command the line names; nil before it is resolved
          # @param stated [String, nil] the role `--as` stated
          # @yield the line's dispatch
          # @return [Object] the block's result
          def as_line_caller(runtime, spec, stated, &)
            return Runtime::Caller.as(role: stated, &) if stated
            return yield if Runtime::Caller.current

            role = launcher_role(runtime, spec)
            role ? Runtime::Caller.as(role: role, &) : Runtime::Caller.unstated(&)
          end

          # The line with its caller's role stated, for a line another process runs (a write
          # forwarded to the main checkout): the role `--as` stated, or the one an enclosing block
          # bound, put back at the end, where the launcher's routing by first word does not see it.
          #
          # @param argv [Array<String>] the line without `--as`
          # @param stated [String, nil] the role `--as` stated
          # @return [Array<String>] the line, with `--as` and the role when a role is known
          def stating_caller(argv, stated)
            bound = Runtime::Caller.current
            role = stated || (bound.role unless bound.nil? || Runtime::Caller.unstated?(bound))
            role ? [*argv, FLAG, role] : argv
          end

          # The first of the command's roles that the launched bluebook's `caller_roles` lists.
          #
          # @api private
          # @return [String, nil] the role, or nil when the setting lists none of them
          def launcher_role(runtime, spec)
            held = caller_roles(runtime)
            Array(spec && spec[:roles]).find { |role| held.include?(role) }
          end

          # The roles the launched bluebook's `launcher` setting says its caller holds.
          #
          # @api private
          # @return [Array<String>] the listed roles, or none
          def caller_roles(runtime)
            return [] unless runtime.respond_to?(:first_bluebook)

            launched = runtime.first_bluebook
            setting = LauncherOptions.settings(runtime, launched.name)
            Array(setting && setting[:caller_roles]).map(&:to_s)
          end
        end
      end
    end
  end
end
