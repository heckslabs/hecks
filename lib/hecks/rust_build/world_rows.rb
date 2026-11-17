# frozen_string_literal: true

require_relative "../text"
require_relative "world_overlay"

module Hecks
  module RustBuild
    # The rows of a checkout's Tickets world, read once per checkout and verb by loading the world
    # file against a collector that keeps the world it declares. The owner's local worlds
    # ({WorldOverlay}) replace a committed verb whole, as they do when the registry boots the
    # folder, so a setting the owner keeps reaches the readers of a worktree too.
    #
    # A cached row keeps a stamp of its source files ({WorldOverlay.stamp}), so an edited, added or
    # removed file is read again at the next call.
    #
    # A checkout with no world file has nothing declared, and its rows are empty. A world file
    # that exists and fails to load also answers an empty row, so a build is never stopped for want
    # of a setting, but the failure is not mistaken for that: it is warned once on stderr, kept for
    # {.unreadable} to name, and never cached, so the next read tries the file again.
    module WorldRows
      # The world file that declares the rows, under a hecks checkout.
      WORLD = "lib/hecks/hecks/tickets.world"

      module_function

      # @param root [String] a hecks checkout
      # @param verb [String] a world verb of the Tickets world
      # @return [Hash] that verb's row, empty for a checkout with no Tickets world, no such line,
      #   or a world that could not be read ({.unreadable} says which)
      def row(root, verb)
        @rows ||= {}
        stamp, row = @rows[key(root, verb)]
        stamp && stamp == stamp_of(root) ? row : read(root, verb)
      end

      # @param root [String] a hecks checkout
      # @return [String, nil] why the checkout's world could not be read by this process, nil when
      #   it was read or not yet asked for
      def unreadable(root) = failures[root]

      # Forgets what was read and what failed, so the next call reads the world again.
      #
      # @return [void]
      def reset!
        @rows = {}
        @failures = {}
        WorldOverlay.reset!
      end

      # @param file [String] a world file
      # @return [Array<Bluebook::World>] the worlds it declares, in order, registered nowhere
      def worlds_in(file)
        worlds = []
        collector = Object.new
        collector.define_singleton_method(:add_world) { |world| worlds << world }
        Hecks.with_registry(collector) { Kernel.load(file) }
        worlds
      end

      # A row read while overlays are left out is kept apart from one read with them.
      def key(root, verb) = [root, verb, Thread.current[:hecks_committed_only] ? :committed : :local]
      private_class_method :key

      def read(root, verb)
        stamp = stamp_of(root)
        row = load(root, verb)
        failures.delete(root)
        @rows[key(root, verb)] = [stamp, row]
        row
      rescue StandardError, ScriptError => e
        failed(root, "#{File.join(root, WORLD)}: #{e.class}: #{Hecks::Text.first_line(e.message)}")
      end
      private_class_method :read

      def stamp_of(root) = [WorldOverlay.stat_of(File.join(root, WORLD)), WorldOverlay.stamp(root)]
      private_class_method :stamp_of

      def load(root, verb)
        file = File.join(root, WORLD)
        return {} unless File.file?(file) && defined?(Hecks.with_registry)

        world = worlds_in(file).first
        return {} unless world

        WorldOverlay.settings(root, world.domain).fetch(verb.to_s) { world.for_verb(verb) }
      end
      private_class_method :load

      def failed(root, reason)
        warn("hecks: the Tickets world could not be read, its settings are left at their defaults: #{reason}") \
          unless failures[root] == reason
        failures[root] = reason
        {}
      end
      private_class_method :failed

      def failures = (@failures ||= {})
      private_class_method :failures
    end
  end
end
