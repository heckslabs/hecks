# frozen_string_literal: true

require "fileutils"
require_relative "../../../adapters/driven/worktree_borrow"

module Hecks
  module Adapters
    class MainIntegration
      # The push train's local world, kept as a link to the owner's. The Ticker's wake sessions
      # start in the train's copy, so a copy with a world of its own (or none) runs them over
      # empty Memory stores and they cannot see the work item they were woken for. The link
      # makes the stores and the owner's switches the same everywhere the pipeline runs. A
      # world that may mint eras or archive a ledger is never linked, and a link already made
      # to one is removed, so the train never reads it.
      class LocalWorld
        # Where the world is, relative to a checkout.
        PATH = File.join("lib", "hecks", "hecks", "hecks.local.world")

        # @param root [String] the train's copy
        # @param main [String] the owner's checkout
        def initialize(root, main)
          @link = File.join(root, PATH)
          @source = File.join(main, PATH)
        end

        # Makes the train's world the link to the owner's, or removes the link when the owner's
        # world may change history.
        #
        # @return [String] what was done
        def sync
          return "no owner world to read" unless File.file?(@source)
          return unlink_refused if WorktreeBorrow.changes_history?(@source)
          return "train world current" if File.symlink?(@link) && File.readlink(@link) == @source

          FileUtils.mkdir_p(File.dirname(@link))
          FileUtils.rm_f(@link)
          File.symlink(@source, @link)
          "linked the train's world to #{@source}"
        end

        private

        def unlink_refused
          FileUtils.rm_f(@link) if File.symlink?(@link)
          "train world not linked: the owner's world may mint eras or archive a ledger"
        end
      end
    end
  end
end
