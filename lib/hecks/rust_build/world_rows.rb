# frozen_string_literal: true

require_relative "../text"

module Hecks
  module RustBuild
    # The rows of a checkout's Tickets world, read once per checkout and verb by loading the world
    # file against a collector that keeps the world it declares.
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
        @rows.fetch([root, verb]) { read(root, verb) }
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
      end

      def read(root, verb)
        row = load(root, verb)
        failures.delete(root)
        @rows[[root, verb]] = row
      rescue StandardError, ScriptError => e
        failed(root, "#{File.join(root, WORLD)}: #{e.class}: #{Hecks::Text.first_line(e.message)}")
      end
      private_class_method :read

      def load(root, verb)
        file = File.join(root, WORLD)
        return {} unless File.file?(file) && defined?(Hecks.with_registry)

        worlds = []
        collector = Object.new
        collector.define_singleton_method(:add_world) { |world| worlds << world }
        Hecks.with_registry(collector) { Kernel.load(file) }
        worlds.first&.for_verb(verb) || {}
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
