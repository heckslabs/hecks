# frozen_string_literal: true

module Hecks
  module RustBuild
    # The compiler cache a build child shares across work items: `sccache`, when the machine has
    # it, wraps `rustc` so a worktree's own target directory reuses what another one compiled.
    #
    # Nothing is installed or required: a machine without `sccache` builds as it did. `sccache`
    # keeps its own cache directory and runs a server process of its own, and it does not cache
    # incremental builds, so the cache comes with `CARGO_INCREMENTAL=0`. A `RUSTC_WRAPPER` or
    # `CARGO_INCREMENTAL` the caller set by hand, empty or not, always wins.
    module CompilerCache
      # The program that wraps `rustc`.
      PROGRAM = "sccache"

      module_function

      # @param base [#[]] the environment the command would otherwise inherit
      # @return [Hash{String => String}] the wrapper and the incremental switch to add; empty when
      #   the base names a wrapper, names no `PATH`, or has no `sccache` on it
      def environment(base = ENV)
        return {} if base.key?("RUSTC_WRAPPER")

        found = program(base["PATH"].to_s)
        return {} unless found

        { "RUSTC_WRAPPER" => found }.merge(base.key?("CARGO_INCREMENTAL") ? {} : { "CARGO_INCREMENTAL" => "0" })
      end

      # @param search [String] a `PATH`
      # @return [String, nil] the first executable `sccache` along it
      def program(search)
        search.split(File::PATH_SEPARATOR).map { |dir| File.join(dir, PROGRAM) }.find { |file| File.executable?(file) }
      end
    end
  end
end
