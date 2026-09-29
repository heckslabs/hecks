# frozen_string_literal: true

require "rbconfig"
require_relative "shell"
require_relative "console_capture"
require_relative "rust_workspace"

module Hecks
  module Adapters
    # The `RustToolchain` port's adapter: generates a domain's Rust source, compiles it (native,
    # WASI, browser) and checks the build against the Ruby engine.
    #
    # Each ask runs the script that already does the work, in a child process, in the workspace
    # `RustWorkspace` names: the checkout's own `rust/`, or a copy of the packaged workspace under
    # the client's `.hecks/rust/<version>/`. The child is told that workspace and a `target/`
    # beside it, so a build never writes into the installed gem. A child that ends non-zero is a
    # refusal whose reason is what it printed.
    class RustToolchain
      # The hecks tools a build asks to run, by ask.
      SCRIPTS = { generate: "project_rust", wasm: "project_wasm", browser_wasm: "project_wasm_browser",
                  conform: "rust_conformance", replay: "rust_conformance_fuzz",
                  coverage: "rust_coverage" }.freeze

      class << self
        # @return [#capture, nil] starts each child; a `Shell` when nil. A spec replaces it, so no
        #   toolchain is needed to test what is asked of it.
        attr_accessor :shell

        # @return [RustWorkspace, nil] the workspace to build in; `RustWorkspace.new` when nil
        attr_accessor :workspace
      end

      # Accepts the arguments every driven adapter is built with and keeps none of them.
      #
      # @param aggregate [Object, nil] unused
      # @param settings [Hash] unused
      # @param root [String, nil] unused
      def initialize(aggregate: nil, settings: {}, root: nil); end

      # Generates the domain's Rust source into the workspace, with a Cargo feature for it.
      #
      # @param held [Hash] the `Build` record: `domain` (its directory)
      # @return [Hash{Symbol => Hash}] `output:` what the generator reported
      # @raise [ConsoleCapture::Failure] when the domain cannot be generated, or the install has no
      #   Rust workspace to build in
      def generate(**held)
        child(:generate, [plain(held[:domain])])
      end

      # Generates the domain, then compiles it to a `wasm32-wasip1` module.
      #
      # @param held [Hash] the `Build` record: `domain`
      # @return [Hash{Symbol => Hash}] `output:` where the module was written
      # @raise [ConsoleCapture::Failure] when the wasm target or the build is missing
      def wasm(**held)
        child(:wasm, [plain(held[:domain])])
      end

      # Generates the domain, then compiles it to an ES module for a browser through wasm-bindgen.
      #
      # @param held [Hash] the `Build` record: `domain`
      # @return [Hash{Symbol => Hash}] `output:` where the module was written
      # @raise [ConsoleCapture::Failure] when the target, the wasm-bindgen version or the build is
      #   missing
      def browser_wasm(**held)
        child(:browser_wasm, [plain(held[:domain])])
      end

      # Replays a step script through the Ruby engine and, when an artifact is named, through that
      # artifact too, and compares what each did.
      #
      # @param held [Hash] the `Build` record: `domain`, `script` (a JSON file of steps) and
      #   `artifact` (`native`, `build`, a `.wasm` file or a binary; Ruby's own result when absent)
      # @return [Hash{Symbol => Hash}] `output:` the comparison, or Ruby's result as JSON
      # @raise [ConsoleCapture::Failure] when the two disagree, or the artifact cannot be run
      def conform(**held)
        child(:conform, [plain(held[:domain]), plain(held[:script]), plain(held[:artifact])].compact)
      end

      # Replays generated step sequences through the Ruby engine and an artifact.
      #
      # @param held [Hash] the `Build` record: `domain`, `artifact`, `seeds` (10 when absent) and
      #   `steps` (25 when absent)
      # @return [Hash{Symbol => Hash}] `output:` how many sequences matched
      # @raise [ConsoleCapture::Failure] at the first seed that diverges, naming how to reproduce it
      def replay(**held)
        argv = [plain(held[:domain]), plain(held[:artifact]), (plain(held[:seeds]) || 10).to_s,
                (plain(held[:steps]) || 25).to_s]
        child(:replay, argv)
      end

      # Checks that every rule of the coverage allowlist still excuses a real gap.
      #
      # @param _held [Hash] the `Build` record, which holds nothing this needs
      # @return [Hash{Symbol => Hash}] `output:` the check's verdict
      # @raise [ConsoleCapture::Failure] when a rule excuses nothing
      def audit(**_held)
        child(:coverage, ["--check-allowlist"])
      end

      # Reports whether each construct of a generated module has a routed implementation.
      #
      # @param module_name [Hash, String] the generated module (a domain's directory name)
      # @param codegen [Hash, String, nil] `ruby` (the default) or `rust`: which generator's
      #   manifest to read
      # @return [String] the report, gaps included: a gap is what the report says, not a refusal
      # @raise [ConsoleCapture::Failure] when there is no such module, or no report could be made
      def rust_coverage(module_name:, codegen: nil)
        argv = [plain(module_name)]
        argv << "--codegen=#{plain(codegen)}" if plain(codegen)
        result = run(:coverage, argv)
        return result.out if result.ok? || result.out.start_with?("=" * 8)

        raise ConsoleCapture::Failure, message_of(result)
      end

      private

      def child(ask, argv)
        result = run(ask, argv)
        raise ConsoleCapture::Failure, message_of(result) unless result.ok?

        { output: { value: result.out } }
      end

      def run(ask, argv)
        space = self.class.workspace || RustWorkspace.new
        env = space.environment.merge("HECKS_NO_3_0_NOTICE" => "1")
        (self.class.shell || Shell.new).capture(RbConfig.ruby, script(SCRIPTS.fetch(ask)), *argv, env: env)
      rescue RustWorkspace::Unavailable => e
        raise ConsoleCapture::Failure, e.message
      end

      def message_of(result)
        text = [result.err, result.out].map(&:strip).reject(&:empty?).join("\n")
        text.empty? ? "the build ended with status #{result.status.exitstatus}" : text
      end

      def script(name) = File.expand_path("../../../../bin/#{name}", __dir__)

      def plain(argument) = argument.is_a?(Hash) ? argument[:value] : argument
    end
  end
end
