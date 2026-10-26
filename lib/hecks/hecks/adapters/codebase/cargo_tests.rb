# frozen_string_literal: true

require_relative "../console_capture"

module Hecks
  module Adapters
    module Codebase
      # Runs `cargo test` for the crates whose fuzzers take their seed counts from the
      # environment, so a person gives a count as an argument and the fuzzer reads the variable
      # it always has.
      module CargoTests
        # Where each crate's tests run, relative to the checkout's `rust/`, the `cargo test`
        # words that select them, and the variables their fuzzers read for a seed count and a
        # first seed.
        TARGETS = {
          "host"   => { dir: "host", words: [], seeds: "HOST_FUZZ_SEEDS", first: nil },
          "parser" => { dir: "parser", words: [], seeds: "HECKS_PARSE_FUZZ_ITERATIONS", first: "HECKS_PARSE_FUZZ_SEED" },
          "json"   => { dir: ".", words: %w[--test json_parse_fuzz], seeds: "JSON_FUZZ_SEEDS", first: nil }
        }.freeze

        module_function

        # Runs `cargo test` for one crate with the seed counts named.
        #
        # @param args [Hash] `crate`, and `seeds` and `seed_start` when named
        # @param tree [Tree] the checkout
        # @param shell [#capture] starts the cargo child
        # @return [String] what cargo printed
        # @raise [ConsoleCapture::Failure] when a test fails or cargo is not installed
        def run(args, tree, shell)
          target = TARGETS.fetch(args[:crate])
          env = fuzz_env(target, args)
          result = shell.capture("cargo", "test", *target[:words], env: env, chdir: tree.path("rust/#{target[:dir]}"))
          raise ConsoleCapture::Failure, printed(result) unless result.ok?

          printed(result)
        end

        # @return [Hash{String => String}] only the fuzz variables the run named and the crate reads
        def fuzz_env(target, args)
          env = { target[:seeds] => args[:seeds]&.to_s }
          env[target[:first]] = args[:seed_start]&.to_s if target[:first]
          env.compact
        end

        def printed(result) = "#{result.out}#{result.err}".strip
      end
    end
  end
end
