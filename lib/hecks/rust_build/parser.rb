# frozen_string_literal: true

require_relative "../rust_build"

module Hecks
  module RustBuild
    # Builds the `hecks-parse` binary from `rust/parser`, the one the bluebook parser specs run, so
    # they need no hand build to reach it.
    #
    #   Parser.call([])
    #
    # Writes `rust/parser/target/debug/hecks-parse`, the path those specs look for.
    module Parser
      module_function

      # @param _argv [Array<String>] unused: the crate has one build
      # @return [Integer] 0 once the binary is built
      # @raise [Failure] when cargo cannot build it
      def call(_argv)
        RustBuild.command!("cargo", "build", chdir: File.join(RustBuild.rust_dir, "parser"))
        0
      end
    end
  end
end
