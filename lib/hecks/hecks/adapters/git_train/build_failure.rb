# frozen_string_literal: true

require_relative "../../../rust_build/toolchain"

module Hecks
  module Adapters
    class GitTrain
      # A drift check that failed because its Cargo build failed, before it compared anything.
      # Such a check found no drift: the build never ran, so its output was never compared with
      # the committed files.
      #
      # The patterns are what the codegen build prints when it fails: the launcher's own
      # `cargo build failed` and `toolchain failure:` lines first, then a compiler error at the
      # start of a line. A diff of generated Rust prints its lines behind a `+`, `-` or space, so a
      # compiler error quoted inside real drift does not match.
      module BuildFailure
        # Lines that show a Cargo build failed.
        FAILED = /cargo build failed|toolchain failure:|^error\[E\d+\]|^error: could not compile/

        module_function

        # @param output [String] what the failed check printed
        # @param env [Hash{String => String}] the variables the check ran with, over the process's
        # @return [String, nil] "codegen build failed under cargo <version> (<path>)", nil when the
        #   output does not show a failed build
        def named(output, env)
          return nil unless output.match?(FAILED)

          found = RustBuild::Toolchain.cargo(ENV.to_h.merge(env))
          cargo = found ? "cargo #{found[:version]} (#{found[:path]})" : "a cargo not found on PATH"
          "codegen build failed under #{cargo}"
        end
      end
    end
  end
end
