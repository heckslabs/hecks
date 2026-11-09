# frozen_string_literal: true

require_relative "../rust_build"
require_relative "session_build"

module Hecks
  module RustBuild
    # Where Cargo writes a crate's build output.
    #
    # A checkout of hecks builds into the crate's own `target/`. An installed copy (a gem, or a
    # bundler checkout of a git revision) sits under `Gem.path`, where every new revision is a new
    # directory, so a build there goes to one shared cache instead: each revision reuses the last
    # one's compiled dependencies, and the output is kept once rather than once per revision.
    # A linked git worktree shares that same cache: agents keep dozens of worktrees, and a `target/`
    # in each one multiplied the build output by the worktree count. The main checkout keeps its
    # own. Where the Tickets world's `session_environment` names a target directory, an installed
    # copy and a worktree build into that one, the directory dispatched sessions already use, so
    # the dependencies compile once on the machine.
    # `CARGO_TARGET_DIR` overrides all of these.
    module TargetDir
      module_function

      # @param crate_dir [String] the crate's directory
      # @param root [String] the hecks copy the crate belongs to
      # @param binary [Boolean] whether the build's binary is run or published afterwards, which
      #   takes a directory of the worktree's own below the shared one
      # @return [String] the directory Cargo writes the crate's output to
      def for(crate_dir, root: ROOT, binary: false)
        SessionBuild.environment(root: root, binary: binary)["CARGO_TARGET_DIR"] ||
          ENV.fetch("CARGO_TARGET_DIR") do
            installed?(root) || worktree?(root) ? shared_for(crate_dir, root, binary: binary) : File.join(crate_dir, "target")
          end
      end

      # @param crate_dir [String] the crate's directory
      # @param root [String] the hecks copy the crate belongs to
      # @param binary [Boolean] whether the build's binary is run or published afterwards
      # @return [String] the world's shared target directory, else the per-crate cache directory
      def shared_for(crate_dir, root, binary: false)
        SessionBuild.target_dir(root: root, binary: binary) || shared(File.basename(crate_dir))
      end

      # @param root [String] the hecks copy to read the world of
      # @return [String] the directory every shared target lives in: the one the Tickets world
      #   names, else the per-user cache's `cargo-target`
      def shared_root(root: ROOT)
        SessionBuild.declared_target_dir(root: root) || shared("").chomp("/")
      end

      # @param root [String] a hecks copy's directory
      # @return [Boolean] whether the copy is installed under one of RubyGems' directories
      def installed?(root)
        Gem.path.any? { |dir| File.expand_path(root).start_with?(File.join(File.expand_path(dir), "")) }
      end

      # @param root [String] a hecks copy's directory
      # @return [Boolean] whether the copy is a linked git worktree (its `.git` is a file)
      def worktree?(root)
        File.file?(File.join(root, ".git"))
      end

      # @param name [String] the crate's name
      # @return [String] the crate's directory in the per-user cache
      #   (`XDG_CACHE_HOME`, else `~/.cache`)
      def shared(name)
        File.join(ENV.fetch("XDG_CACHE_HOME", File.join(Dir.home, ".cache")), "hecks", "cargo-target", name)
      end
    end
  end
end
