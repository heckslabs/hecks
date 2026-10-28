require_relative "launcher_options"

module Hecks
  module Adapters
    module Driving
      # The launcher's help for someone starting out: a folder with no bluebook in it has no use yet
      # for the commands that act on a domain, so the help lists only the `newcomer` commands the
      # bluebook's `launcher` setting names (`hecks --all` lists the rest).
      module Newcomer
        # How deep under a directory a bluebook may sit and still make it a project:
        # `Hecks.bluebook` beside it, or `bluebook/pizzas.bluebook` one folder down, as the
        # examples keep theirs.
        PROJECT_GLOBS = ["*.bluebook", "*/*.bluebook", "*/*/*.bluebook"].freeze

        module_function

        # Whether the person is in a folder with no bluebook in it, outside a hecks checkout.
        #
        # @param dir [String] where the command line was typed
        # @param env [#[]] the environment
        # @return [Boolean] true when no `.bluebook` stands in `dir` or up to two folders below it
        def applies?(dir = Dir.pwd, env = ENV)
          return false if LauncherOptions.maintainer?(dir, env)

          PROJECT_GLOBS.none? { |pattern| bluebook_under?(dir, pattern) }
        end

        # The help options a newcomer gets: only the setting's `newcomer` commands, and no
        # bluebooks.
        #
        # @param settings [Hash, nil] the bluebook's `launcher` setting
        # @return [Hash{Symbol => Object}, nil] `:only` and `:bluebooks`, or nil when the bluebook
        #   names no newcomer commands
        def audience(settings)
          return unless settings && settings[:newcomer]

          { only: Array(settings[:newcomer]).map(&:to_s), declarations: [] }
        end

        # Whether `pattern` finds a bluebook under `dir`; a folder the person may not read holds
        # none.
        # @api private
        def bluebook_under?(dir, pattern)
          Dir.glob(File.join(File.expand_path(dir), pattern)).any?
        rescue SystemCallError
          false
        end
      end
    end
  end
end
