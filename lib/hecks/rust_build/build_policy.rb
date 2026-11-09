# frozen_string_literal: true

require "etc"
require_relative "../cache_dir"

module Hecks
  module RustBuild
    # How hard a Rust build that hecks starts may work: the Tickets world's `rust_build` line caps
    # the jobs Cargo runs at once and sets a `nice` increment, for every checkout, the owner's main
    # one included.
    #
    # Cargo uses every core by default, and one `rustc` was seen at 384% of a core. A cap of a few
    # jobs keeps a build from taking the machine, and `nice` keeps it behind the owner's work. A
    # checkout with no Tickets world or no such line gets neither, so a build outside a hecks
    # checkout is left as it was. A `CARGO_BUILD_JOBS` set by hand always wins.
    module BuildPolicy
      # The world verb that carries the setting.
      VERB = "rust_build"

      module_function

      # @param base [#[]] the environment
      # @return [String] the directory the lock and the kept binaries live in: under
      #   `HECKS_CACHE_DIR` when it is named (as the spec runs name it), else the cache directory
      def cache_root(base: ENV)
        named = base["HECKS_CACHE_DIR"].to_s
        named.empty? ? Hecks::CacheDir.path("rust-build") : File.join(named, "rust-build")
      end

      # @param root [String] a hecks checkout
      # @return [Hash] the `rust_build` row of the Tickets world, empty when it has none
      def row(root) = SessionBuild.world_row(root, VERB)

      # @param root [String] a hecks checkout
      # @param cores [Integer] how many cores the machine has
      # @return [Integer, nil] how many jobs a build may run at once: the line's `jobs`, else a
      #   third of the cores and at least two; nil when the checkout declares no `rust_build` line
      def jobs(root, cores: Etc.nprocessors)
        declared = row(root)
        return nil if declared.empty?

        Integer(declared[:jobs] || [2, cores / 3].max)
      end

      # @param root [String] a hecks checkout
      # @return [Integer, nil] the `nice` increment, nil for none
      def nice(root) = row(root)[:nice]

      # @param root [String] a hecks checkout
      # @param base [#[]] the environment the child would otherwise inherit
      # @return [Hash{String => String}] the job cap to add; none when the caller already set
      #   `CARGO_BUILD_JOBS` or the checkout declares no line
      def environment(root:, base: ENV)
        count = base["CARGO_BUILD_JOBS"] ? nil : jobs(root)
        count ? { "CARGO_BUILD_JOBS" => count.to_s } : {}
      end
    end
  end
end
