# frozen_string_literal: true

require "digest"
require "fileutils"

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

      # A build that only tests shares the one target directory, since Cargo's lock serialises a
      # build. A build that runs or publishes a binary Cargo produced (`binary: true`) takes a
      # directory of its own below it, so another worktree cannot replace the binary between the
      # build and the run. A session inherits the shared directory from the dispatcher; a binary
      # build replaces that one too, while a directory named by hand always wins.
      #
      # @param root [String] a hecks checkout
      # @param base [#[]] the environment the child would otherwise inherit
      # @param binary [Boolean] whether the build's binary is run or published afterwards
      # @return [Hash{String => String}] the variables to add; none when the caller already named
      #   a target directory, so `CARGO_TARGET_DIR` set by hand still wins
      def environment(root: ROOT, base: ENV, binary: false)
        shared = environment_of(row(root))["CARGO_TARGET_DIR"]
        given = base["CARGO_TARGET_DIR"]
        return {} if shared.nil? || (given && !(binary && File.expand_path(given) == shared))

        { "CARGO_TARGET_DIR" => binary ? claim(slot(shared, root), root) : shared }
      end

      # A lookup: it answers the directory and makes nothing. A build that is about to write to a
      # slot claims it ({#claim}); `environment` does so for the child it prepares.
      #
      # @param root [String] a hecks checkout
      # @param binary [Boolean] whether the build's binary is run or published afterwards
      # @return [String, nil] the target directory the world names for a build in +root+, nil when
      #   it names none
      def target_dir(root: ROOT, binary: false)
        shared = environment_of(row(root))["CARGO_TARGET_DIR"]
        shared && binary ? slot(shared, root) : shared
      end

      # The directory a build that runs its own binary writes to, for a workspace in +root+. A
      # directory named by hand wins, except the world's shared one, which a dispatched session
      # inherits and which no two worktrees may write a binary to. Outside a linked worktree the
      # world names no directory, and the workspace keeps its own `target/`. A lookup: it makes
      # nothing.
      #
      # @param root [String] a hecks checkout
      # @param base [#[]] the environment the child would otherwise inherit
      # @param relative_to [String, nil] the directory a relative value of `CARGO_TARGET_DIR` is
      #   taken from, which is the directory Cargo runs in; the working directory when nil
      # @return [String, nil] the directory, nil when the workspace's own `target/` serves
      def binary_dir(root: ROOT, base: ENV, relative_to: nil)
        given = base["CARGO_TARGET_DIR"]
        shared = declared_target_dir(root: root)
        named = given && File.expand_path(given, relative_to || Dir.pwd)
        return named if named && (shared.nil? || named != shared)

        target_dir(root: root, binary: true)
      end

      # @param root [String] a hecks checkout
      # @return [String, nil] the shared target directory the world names, whether or not +root+ is
      #   a linked worktree
      def declared_target_dir(root: ROOT) = environment_of(declared(root))["CARGO_TARGET_DIR"]

      # @param root [String] a hecks checkout
      # @return [String] the name of the directory a binary build in +root+ keeps below the shared
      #   one: the checkout's name and a digest of its path, so two checkouts never share one
      def slug(root)
        path = File.expand_path(root)
        "#{File.basename(path)}-#{Digest::SHA256.hexdigest(path)[0, 8]}"
      end

      # The names a checkout's slot may carry: its path as given and as the file system spells it,
      # which differ where a path crosses a symlink (`/var` and `/private/var`).
      #
      # @param root [String] a hecks checkout
      # @return [Array<String>] the distinct slot names
      def slugs(root)
        [slug(root), slug(File.realpath(root))].uniq
      rescue SystemCallError
        [slug(root)]
      end

      # File in a slot naming the checkout it belongs to, so a prune can tell a slot whose
      # checkout is gone from one whose checkout git lists under another spelling.
      OWNER = ".owner"

      # @param shared [String] the world's shared target directory
      # @param root [String] the checkout the slot belongs to
      # @return [String] the slot below +shared+; nothing is made
      def slot(shared, root) = File.join(shared, slug(root))

      # Makes the slot and records +root+ as its owner, before a build writes to it; a slot that
      # cannot be written to is left unrecorded.
      #
      # @param dir [String] a slot
      # @param root [String] the checkout the slot belongs to
      # @return [String] +dir+
      def claim(dir, root)
        file = File.join(dir, OWNER)
        owner = File.realpath(root)
        unless File.file?(file) && File.read(file) == owner
          FileUtils.mkdir_p(dir)
          File.write(file, owner)
        end
        dir
      rescue SystemCallError
        dir
      end

      # Claims +dir+ when it is the slot of +root+, for a build that took its directory from a
      # lookup; any other directory (one named by hand, the workspace's own `target/`) is left
      # alone.
      #
      # @param dir [String] the directory a build is about to write to
      # @param root [String] the checkout the build belongs to
      # @return [String] +dir+
      def claim_slot(dir, root) = File.basename(dir) == slug(root) ? claim(dir, root) : dir

      # @param path [String] a file or directory in a hecks checkout
      # @return [String] the checkout it is in: the nearest directory above it with a `.git` or a
      #   `hecks.gemspec`, else the checkout this code runs from
      def root_of(path)
        dir = File.expand_path(path.to_s)
        until File.exist?(File.join(dir, ".git")) || File.file?(File.join(dir, "hecks.gemspec"))
          parent = File.dirname(dir)
          return ROOT if parent == dir

          dir = parent
        end
        dir
      end

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
      def row(root) = File.file?(File.join(root, ".git")) ? declared(root) : {}

      # @param root [String] a hecks checkout
      # @return [Hash] the world's `session_environment` row, read once per checkout
      def declared(root)
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
