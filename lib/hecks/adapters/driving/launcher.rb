# frozen_string_literal: true

require_relative "../driven/worktree_overlay"

module Hecks
  module Adapters
    module Driving
      # The launcher a process was started by, when it is not this checkout's own `exe/hecks`.
      #
      # A launcher that boots a domain from another repository (a downstream project on a pinned
      # Hecks) sets `HECKS_LAUNCHER` to its own executable. The kept-aggregate check then judges
      # the repository that launcher belongs to, which holds the overlay the booted domain loads,
      # and names that launcher in its refusal, not `exe/hecks` of the checkout it works on.
      module Launcher
        # The variable a launcher sets to the absolute path of its own executable.
        KEY = "HECKS_LAUNCHER"

        # The launcher a checkout has when none is named.
        DEFAULT = "exe/hecks"

        module_function

        # @param env [#[]] where `HECKS_LAUNCHER` is read
        # @return [String, nil] the named launcher's absolute path, or nil when none is named
        def path(env)
          named = env[KEY].to_s
          File.expand_path(named) unless named.empty?
        end

        # @param env [#[]] where `HECKS_LAUNCHER` is read
        # @return [String, nil] the root of the repository the named launcher belongs to
        def root(env)
          found = path(env)
          WorktreeOverlay.ascend_to_git(File.dirname(found)) if found
        end

        # @param env [#[]] where `HECKS_LAUNCHER` is read
        # @return [String] the command a refusal tells the reader to run
        def command(env) = path(env) || DEFAULT
      end
    end
  end
end
