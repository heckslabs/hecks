# frozen_string_literal: true

require "pathname"
require_relative "../text"
require_relative "../adapters/driven/worktree_overlay"

module Hecks
  module RustBuild
    # The owner's local worlds as the rows of a checkout's Tickets world see them: the settings each
    # `*.local.world` declares for the world's domain, folded in file order with a later verb
    # replacing an earlier one whole, as `Registry::Merging#merge_worlds` folds them at boot.
    #
    # The files are the ones the folder overlay loads beside the domain, read from the checkout
    # itself when it keeps any, else from the main checkout a linked worktree was made from, since
    # a worktree keeps none of the gitignored files. Persistence lines are left out: a worktree's
    # store is Memory by design, so a row never carries the owner's database. A file that cannot be
    # read adds nothing and is named once on stderr.
    module WorldOverlay
      # Where the overlay files live, relative to a checkout's root.
      DIRECTORY = "lib/hecks/hecks"

      # The local worlds, in the order the folder overlay loads them.
      FILES = ["environments/local.world", "*.local.world"].freeze

      # The settings keys of a persistence line, bare and qualified by its adapter.
      PERSISTENCE = /\Apersisted_by(:|\z)/

      module_function

      # @param root [String] a hecks checkout
      # @param domain [String] the domain whose world the rows belong to
      # @return [Hash{String => Hash}] the overlay's settings by verb, empty while
      #   `Adapters::FolderOverlay.committed_only` runs or when no overlay is kept
      def settings(root, domain)
        return {} if Thread.current[:hecks_committed_only]

        files(home(root)).each_with_object({}) { |file, merged| merged.merge!(read(file, domain)) }
      end

      # @param root [String] a hecks checkout
      # @return [String] the checkout whose overlay applies: the root when it keeps one, else the
      #   main checkout of a linked worktree, else the root
      def home(root)
        return root unless files(root).empty?

        worktree = Adapters::WorktreeOverlay.checkout_root(root)
        (worktree && Adapters::WorktreeOverlay.main_checkout(worktree)) || root
      end

      # @param root [String] a hecks checkout
      # @return [Array<String>] its local world files, in load order
      def files(root) = FILES.flat_map { |pattern| Dir[File.join(root, DIRECTORY, pattern)].sort }

      # @param root [String] a hecks checkout
      # @return [Array] the modification time and size of each overlay file that applies to the
      #   checkout, empty while `Adapters::FolderOverlay.committed_only` runs; it differs after an
      #   overlay file is edited, added or removed
      def stamp(root)
        return [] if Thread.current[:hecks_committed_only]

        files(home(root)).map { |file| [file, stat_of(file)] }
      end

      # @param file [String] a path
      # @return [Array<Integer>, nil] its modification time in nanoseconds and size, nil when absent
      def stat_of(file)
        stat = File.stat(file)
        [(stat.mtime.to_r * 1_000_000_000).to_i, stat.size]
      rescue SystemCallError
        nil
      end

      # Forgets which files were named as unreadable.
      #
      # @return [void]
      def reset! = (@noted = {})

      def read(file, domain)
        worlds = WorldRows.worlds_in(file).select { |world| world.domain == domain }
        worlds.each_with_object({}) { |world, merged| merged.merge!(world.settings) }
              .reject { |verb, _| verb.match?(PERSISTENCE) }
      rescue StandardError, ScriptError => e
        noted(file, "#{e.class}: #{Hecks::Text.first_line(e.message)}")
      end
      private_class_method :read

      def noted(file, reason)
        @noted ||= {}
        warn("hecks: the local world #{file} could not be read, its settings are left out: #{reason}") \
          unless @noted.key?(file)
        @noted[file] = reason
        {}
      end
      private_class_method :noted
    end
  end
end
