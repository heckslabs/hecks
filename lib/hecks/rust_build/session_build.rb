# frozen_string_literal: true

module Hecks
  module RustBuild
    # What the Tickets world's `session_environment` line says every Rust build child runs with:
    # one shared Cargo target directory and a `nice` increment.
    #
    # A dispatched session gets both from the dispatcher (`Dispatching::Settings`). A build the
    # owner, a gate, the spec runner or the landing path starts reads the same line here, so every
    # `cargo` on the machine writes to one target directory and yields to the owner's work. The
    # line is read once per worktree from the committed world file, and a world that cannot be
    # read answers nothing: a build never fails for want of a setting.
    module SessionBuild
      # The world verb that carries the setting.
      VERB = "session_environment"

      # The world file that declares it, under a hecks checkout.
      WORLD = "lib/hecks/hecks/tickets.world"

      module_function

      # @param row [Hash] the `session_environment` row of the Tickets world
      # @return [Hash{String => String}] the variables a build child starts with
      def environment_of(row)
        dir = row[:cargo_target_dir]
        dir ? { "CARGO_TARGET_DIR" => File.expand_path(dir.to_s) } : {}
      end

      # @param row [Hash] the `session_environment` row of the Tickets world
      # @return [Integer, nil] the `nice` increment, nil for none
      def nice_of(row) = row[:nice]

      # @param root [String] a hecks checkout
      # @param base [#key?] the environment the child would otherwise inherit
      # @return [Hash{String => String}] the variables to add; none when the caller already named
      #   a target directory, so `CARGO_TARGET_DIR` set by hand still wins
      def environment(root: ROOT, base: ENV)
        base.key?("CARGO_TARGET_DIR") ? {} : environment_of(row(root))
      end

      # @param root [String] a hecks checkout
      # @return [String, nil] the shared target directory the world names, nil when it names none
      def target_dir(root: ROOT) = environment_of(row(root))["CARGO_TARGET_DIR"]

      # @param command [Array<String>] a build command and its arguments
      # @param root [String] a hecks checkout
      # @return [Array<String>] the command, run under `nice` when the world names an increment
      def command(command, root: ROOT)
        increment = nice_of(row(root))
        increment ? ["nice", "-n", increment.to_s, *command] : command
      end

      # Only a linked git worktree, where an agent works, takes the setting: the owner's main
      # checkout keeps its own `target/` and builds at full priority.
      #
      # @param root [String] a hecks checkout
      # @return [Hash] the world's `session_environment` row, empty for a checkout that is not a
      #   linked worktree or when none can be read
      def row(root)
        return {} unless File.file?(File.join(root, ".git"))

        @rows ||= {}
        @rows.fetch(root) { @rows[root] = load_row(root) }
      end

      # Forgets what was read, so the next call reads the world again.
      #
      # @return [void]
      def reset! = @rows = {}

      # @return [Hash] the row, read by loading the world file against a collector that keeps the
      #   world it declares
      def load_row(root)
        file = File.join(root, WORLD)
        return {} unless File.file?(file) && defined?(Hecks.with_registry)

        worlds = []
        collector = Object.new
        collector.define_singleton_method(:add_world) { |world| worlds << world }
        Hecks.with_registry(collector) { Kernel.load(file) }
        worlds.first&.for_verb(VERB) || {}
      rescue StandardError, ScriptError
        {}
      end
      private_class_method :load_row
    end
  end
end
