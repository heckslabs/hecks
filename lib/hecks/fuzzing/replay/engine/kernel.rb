# frozen_string_literal: true

require "json"
require "open3"
require_relative "../../../rust_build/kernel_input"

module Hecks
  module Fuzzing
    module Engine
      # The Rust kernel as an engine: each call runs a kernel binary built for the domain's Cargo
      # feature once over the whole sequence, with the IR tables `RustBuild::KernelInput` builds,
      # and answers its output. The kernel's one-shot run carries all six wire fields, queries
      # and refusal kinds included; its `--serve` session does not yet.
      class Kernel
        # Raised when the binary exits unsuccessfully: a crash, not a refusal.
        class Failed < StandardError; end

        # @return [String] the kernel binary this engine runs
        attr_reader :binary

        # @param binary [String] a kernel built for one domain (`cargo build --features <domain>`)
        def initialize(binary)
          @binary = binary
        end

        # @param domain_path [String] the domain directory, whose generated IR feeds the tables
        # @param steps [Array<Hash>] the step list
        # @param identity [Array<String>, nil] the ids the identity port hands out, in order
        # @return [Hash] the kernel's run output, parsed
        # @raise [Failed] when the binary exits unsuccessfully
        def call(domain_path, steps, identity: nil)
          input = RustBuild::KernelInput.json(domain_path, steps, identity: identity)
          stdout, status = Open3.capture2(binary, stdin_data: input)
          raise Failed, "#{binary} exited #{status.exitstatus}: #{stdout}" unless status.success?

          JSON.parse(stdout)
        end
      end
    end
  end
end
