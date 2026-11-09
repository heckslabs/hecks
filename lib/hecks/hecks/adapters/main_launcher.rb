# frozen_string_literal: true

module Hecks
  module Adapters
    # The launcher of the main checkout, which holds the ledgers. A linked worktree's own launcher
    # runs in Memory and loses what it writes, so a command a session runs on the ledgers goes
    # through this one, found from the checkout's git directory.
    module MainLauncher
      # The checkout this file belongs to.
      CHECKOUT = File.expand_path("../../../..", __dir__)

      # What a linked worktree's `.git` file says: the main checkout's git directory it hangs from.
      WORKTREE_POINTER = %r{\Agitdir:\s*(.+?)/\.git/worktrees/[^/\n]+\s*\z}

      module_function

      # @param checkout [String] a checkout or a linked worktree of it
      # @return [String, nil] the absolute path of the main checkout's `exe/hecks`, or nil if absent
      def path(checkout = CHECKOUT)
        launcher = File.join(main_root(checkout), "exe", "hecks")
        File.executable?(launcher) ? launcher : nil
      end

      # @return [String] the main checkout's root: the checkout itself unless `.git` is a pointer
      def main_root(checkout)
        pointer = File.join(checkout, ".git")
        return checkout unless File.file?(pointer)

        File.read(pointer)[WORKTREE_POINTER, 1] || checkout
      end
    end
  end
end
