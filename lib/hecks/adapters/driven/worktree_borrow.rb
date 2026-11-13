require_relative "worktree_overlay"

module Hecks
  module Adapters
    # The main checkout whose local files a linked worktree loads as its own, so the worktree's
    # commands see the same dev databases instead of starting in Memory. Nothing is lent to the
    # spec runner or a Memory environment, which stay in Memory and off the live ledgers; to a
    # worktree that keeps a local file of its own, as the push train does with its generated
    # overlay; or from a main checkout whose local world may mint eras or archive a ledger, which
    # a worktree's code must never do to the owner's data.
    module WorktreeBorrow
      # Set by spec_helper for the spec process and every child, which write where they stand.
      SPEC_SWITCH = "HECKS_WRITES_LOCAL".freeze

      # The environments that keep a boot in Memory whatever the local files say.
      MEMORY_ENVIRONMENTS = %w[memory test].freeze

      # The world settings that let a boot change a store's history; no borrowed world has them.
      HISTORY_SETTINGS = /^\s*(mint_eras|disposable_ledger)\s+true\b/

      module_function

      # @param directory [String] a directory inside a checkout
      # @param env [#[]] where the spec switch and the environment are read
      # @return [String, nil] the main checkout's root when this worktree borrows its local files
      def from(directory, env: ENV)
        return if spec_runner?(env)

        worktree = WorktreeOverlay.checkout_root(directory)
        main = worktree && WorktreeOverlay.main_checkout(worktree)
        main if main && WorktreeOverlay.overlay_files(worktree).empty? && lends?(main)
      end

      # @param directory [String] a domain directory inside a linked worktree
      # @param env [#[]] where the spec switch and the environment are read
      # @return [String, nil] the same directory in the main checkout, when its local files are lent
      def directory(directory, env: ENV)
        main = from(directory, env: env)
        return unless main

        relative = File.expand_path(directory).delete_prefix(WorktreeOverlay.checkout_root(directory))
        found = File.join(main, relative)
        found if Dir[File.join(found, "*.local.{hecksagon,world}")].none? { |file| changes_history?(file) }
      end

      # @param env [#[]] the process environment
      # @return [Boolean] whether the process is the spec runner or a Memory boot
      def spec_runner?(env)
        !env[SPEC_SWITCH].to_s.empty? || MEMORY_ENVIRONMENTS.include?(env["HECKS_ENVIRONMENT"].to_s.strip)
      end

      # @param main [String] the main checkout's root
      # @return [Boolean] whether it holds local files and none may change a store's history
      def lends?(main)
        files = WorktreeOverlay.overlay_files(main)
        !files.empty? && files.none? { |file| changes_history?(File.join(main, file)) }
      end

      # @param file [String] a local hecksagon or world
      # @return [Boolean] whether it turns on minting eras or a disposable ledger
      def changes_history?(file)
        File.read(file).match?(HISTORY_SETTINGS)
      end
    end
  end
end
