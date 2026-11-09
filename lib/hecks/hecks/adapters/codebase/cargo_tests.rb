# frozen_string_literal: true

require_relative "../console_capture"
require_relative "../../../rust_build/session_build"
require_relative "../../../rust_build/build_lock"

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
          env = Hecks::RustBuild::SessionBuild.environment(root: tree.root).merge(fuzz_env(target, args))
          command = Hecks::RustBuild::SessionBuild.command(["cargo", "test", *target[:words]], root: tree.root)
          result = locked(shell, command, env, tree.path("rust/#{target[:dir]}"))
          raise ConsoleCapture::Failure, printed(result) unless result.ok?

          printed(result)
        end

        # @return [Shell::Result] what cargo did, run while the machine's build lock is held
        def locked(shell, command, env, dir)
          Hecks::RustBuild::BuildLock.building(command) do |held|
            shell.capture(*command, env: held.merge(env), chdir: dir)
          end
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
