# frozen_string_literal: true

require "fileutils"
require "pathname"
require_relative "../../../adapters/driven/worktree_borrow"
require_relative "../../../adapters/driven/worktree_overlay"

module Hecks
  module Adapters
    class MainIntegration
      # The push train's local files, kept as links to the owner's. The Ticker's wake sessions and
      # the clock's beats run in the train's copy, so a copy that lacks a local world or hecksagon
      # the owner keeps runs those bluebooks over empty Memory stores. Every overlay file of the
      # owner's checkout (`WorktreeOverlay::OVERLAY_PATTERNS`: each `*.local.world`, each
      # `*.local.hecksagon` and `environments/local.*`) is linked, except the copy's own generated
      # `hecks.local.hecksagon`. A world that may mint eras or archive a ledger is never linked,
      # and a link already made to one is removed, so the train never reads it.
      class LocalWorld
        # Where the owner's main world is, relative to a checkout.
        PATH = File.join("lib", "hecks", "hecks", "hecks.local.world")

        # The overlay the copy writes for itself from the kept rows, never linked.
        OWN = File.join("lib", "hecks", "hecks", "hecks.local.hecksagon")

        # @param root [String] the train's copy
        # @param main [String] the owner's checkout
        def initialize(root, main)
          @root = root
          @main = main
        end

        # Links each of the owner's overlay files into the copy, or removes the link to a world
        # that may change history.
        #
        # @return [String] what was done
        def sync
          files = WorktreeOverlay.overlay_files(@main) - [OWN]
          return "no owner world to read" if files.empty?

          said = files.filter_map { |relative| link(relative) }
          said.empty? ? "train world current" : said.join("; ")
        end

        private

        def link(relative)
          source = File.join(@main, relative)
          target = File.join(@root, relative)
          return unlink_refused(target, relative) if history_changing?(source)
          return if File.symlink?(target) && File.readlink(target) == source

          FileUtils.mkdir_p(File.dirname(target))
          FileUtils.rm_f(target)
          File.symlink(source, target)
          "linked the train's #{relative} to #{source}"
        end

        def history_changing?(source) = source.end_with?(".world") && WorktreeBorrow.changes_history?(source)

        def unlink_refused(target, relative)
          FileUtils.rm_f(target) if File.symlink?(target)
          "train world not linked: the owner's #{relative} may mint eras or archive a ledger"
        end
      end
    end
  end
end
