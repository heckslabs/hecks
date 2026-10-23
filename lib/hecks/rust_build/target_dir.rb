# frozen_string_literal: true

require_relative "../rust_build"

module Hecks
  module RustBuild
    # Where Cargo writes a crate's build output.
    #
    # A checkout of hecks builds into the crate's own `target/`. An installed copy (a gem, or a
    # bundler checkout of a git revision) sits under `Gem.path`, where every new revision is a new
    # directory, so a build there goes to one shared cache instead: each revision reuses the last
    # one's compiled dependencies, and the output is kept once rather than once per revision.
    # `CARGO_TARGET_DIR` overrides both.
    module TargetDir
      module_function

      # @param crate_dir [String] the crate's directory
      # @param root [String] the hecks copy the crate belongs to
      # @return [String] the directory Cargo writes the crate's output to
      def for(crate_dir, root: ROOT)
        ENV.fetch("CARGO_TARGET_DIR") do
          installed?(root) ? shared(File.basename(crate_dir)) : File.join(crate_dir, "target")
        end
      end

      # @param root [String] a hecks copy's directory
      # @return [Boolean] whether the copy is installed under one of RubyGems' directories
      def installed?(root)
        Gem.path.any? { |dir| File.expand_path(root).start_with?(File.join(File.expand_path(dir), "")) }
      end

      # @param name [String] the crate's name
      # @return [String] the crate's directory in the per-user cache (`XDG_CACHE_HOME`, else `~/.cache`)
      def shared(name)
        File.join(ENV.fetch("XDG_CACHE_HOME", File.join(Dir.home, ".cache")), "hecks", "cargo-target", name)
      end
    end
  end
end
