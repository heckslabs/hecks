# frozen_string_literal: true

require_relative "tree"
require_relative "../../../cli/pattern_cases"
require_relative "../../../cli/refresh_rspec_runtime_baseline"
require_relative "../../../cli/rspec_io_parallel_files"
require_relative "../../../cli/rspec_shard_files"
require_relative "../../../cli/seed_semantics_corpus"
require_relative "../../../cli/stress_concurrency_specs"
require_relative "test_runner"
require_relative "sqlite_fixture"

module Hecks
  module Adapters
    module Codebase
      # What Codebase's `TestSuiteRun` asks of the working tree: the tooling around this
      # repository's specs.
      #
      # The tooling owns its options, so each ask runs one of the `Hecks::CLI` commands in this
      # process from the checkout's root, except a single example (the `TestRunner` adapter runs it)
      # and the persistence fixtures (the `SqliteFixture` adapter). A listing is a pure read.
      # Refreshing the committed timings, regenerating the fixtures and writing the committed spec
      # list change tracked files, so unconfirmed they report what they would do and write nothing.
      module TestSuite
        # Every operation this family carries out.
        OPERATIONS = %w[refresh_runtime_baseline run_spec_example stress_concurrency
                        regenerate_legacy_fixtures seed_semantics_corpus write_io_parallel_spec_list].freeze

        # The tag filter the postgres job lists its specs by when none is named.
        DEFAULT_TAGS = "--tag io --tag ~fuzzing"

        # The committed files a baseline refresh writes.
        BASELINES = %w[.github/rspec_runtime_baseline.log .github/postgres_io_runtime_baseline.log].freeze

        module_function

        # Carries out one operation.
        #
        # @param operation [String] one of `OPERATIONS`
        # @param held [Hash] the `TestSuiteRun` record's fields
        # @param tree [Tree] the working tree, already known to be a hecks checkout
        # @param shell [#capture, nil] starts the fixtures' child process
        # @return [String] what was found, run or written
        # @raise [ConsoleCapture::Failure] when a run fails or a script is refused
        def call(operation, held, tree, shell: nil)
          args = plain(held)
          case operation
          when "refresh_runtime_baseline" then refresh(args, tree)
          when "run_spec_example" then TestRunner.new(tree).run(file: args[:file], example: args[:example])
          when "stress_concurrency"
            answer { Hecks::CLI::StressConcurrencySpecs.call(stress_flags(args), root: tree.root) }
          when "regenerate_legacy_fixtures"
            SqliteFixture.new(tree, shell: shell).regenerate(confirm: args[:confirm] == true)
          when "seed_semantics_corpus"
            answer { Hecks::CLI::SeedSemanticsCorpus.call(root: tree.root, env: seed_env(args)) }
          else write_list(args, tree)
          end
        end

        # A pure read: a listing, or the recorded pattern cases.
        #
        # @param operation [String] `shard_specs`, `list_io_parallel_specs`, `record_pattern_cases`
        # @param args [Hash] the query's plain arguments
        # @param tree [Tree] the checkout
        # @param shell [#capture, nil] unused: every listing is read in this process
        # @return [String] what the command printed to stdout
        # @raise [ConsoleCapture::Failure] when the command refuses its arguments
        def report(operation, args, tree, shell: nil)
          case operation
          when "shard_specs"
            read { |out| Hecks::CLI::RspecShardFiles.call(shard_args(args), root: tree.root, out: out) }
          when "list_io_parallel_specs"
            read { |out| Hecks::CLI::RspecIoParallelFiles.call(list_args(args), root: tree.root, out: out) }
          else read { |out| Hecks::CLI::PatternCases.call(out: out) }
          end
        end

        # Runs a command in this process and answers what it printed to stdout only, for a command
        # whose stdout is its data and whose stderr is progress.
        #
        # @yield [out] the command, given the stream its data goes to; it answers an exit status
        # @yieldparam out [StringIO] where the data goes
        # @return [String] the data, without the trailing newline
        # @raise [ConsoleCapture::Failure] with what it printed when the status is not 0
        def read
          out = StringIO.new
          outcome = ConsoleCapture.capture { exit(yield(out)) }
          raise ConsoleCapture::Failure, outcome.output.strip unless outcome.ok?

          out.string.chomp
        end

        # Runs a command in this process and answers everything it printed.
        #
        # @yield the command; it answers an exit status
        # @return [String] what it printed to stdout and stderr
        # @raise [ConsoleCapture::Failure] with what it printed when the status is not 0
        def answer
          ConsoleCapture.answer { exit(yield) }
        end

        # @param held [Hash] the record's fields, each perhaps a value object's `{ value: x }`
        # @return [Hash] the same fields as plain values
        def plain(held) = held.transform_values { |value| value.is_a?(Hash) ? value[:value] : value }

        # @param args [Hash] `group`, `groups` and `runtime_log`
        # @return [Array<String>] the script's arguments
        def shard_args(args) = [args[:group].to_s, args[:groups].to_s, *args[:runtime_log]]

        # @param args [Hash] `exclude`, `tags` and `check`
        # @return [Array<String>] the script's arguments: `--check FILE`, the pattern, then the tags
        def list_args(args)
          check = args[:check] ? ["--check", args[:check]] : []
          [*check, args[:exclude].to_s, "--", *tag_words(args)]
        end

        # @param args [Hash] `tags`, perhaps absent
        # @return [Array<String>] the tag filter, one word each
        def tag_words(args) = (args[:tags] || DEFAULT_TAGS).split

        # @param args [Hash] `workers` and `from_run`
        # @param tree [Tree] the checkout whose baselines are rewritten
        # @return [String] what was written, or (unconfirmed) what would be
        # @raise [ConsoleCapture::Failure] when the refresh ends badly
        def refresh(args, tree)
          source = args[:from_run] ? ["--from-run", args[:from_run]] : [*args[:workers]&.to_s]
          return answer { Hecks::CLI::RefreshRspecRuntimeBaseline.call(source, root: tree.root) } if args[:confirm] == true

          "dry run, would #{args[:from_run] ? "read CI run #{args[:from_run]}'s timings" : 'time a local run'} " \
            "and rewrite #{BASELINES.join(', ')} (add --confirm)"
        end

        # @param args [Hash] `runs`, `parallel` and `seed_start`
        # @return [Array<String>] the script's flags for those that are named
        def stress_flags(args)
          { "--runs" => :runs, "--parallel" => :parallel, "--seed-start" => :seed_start }
            .filter_map { |flag, name| [flag, args[name].to_s] if args[name] }.flatten
        end

        # @param args [Hash] `fixture`, perhaps absent
        # @return [Hash{String => String}] the variable that names the one fixture to re-seed
        def seed_env(args) = args[:fixture] ? { "SEED" => args[:fixture] } : {}

        # @param args [Hash] `exclude`, `tags`, `write` and `confirm`
        # @param tree [Tree] the checkout whose spec list is written
        # @return [String] what was written, or (unconfirmed) how many files would be
        # @raise [ConsoleCapture::Failure] when the listing is refused
        def write_list(args, tree)
          if args[:confirm] == true
            words = ["--write", args[:write], args[:exclude], "--", *tag_words(args)]
            answer { Hecks::CLI::RspecIoParallelFiles.call(words, root: tree.root) }
            return "wrote #{args[:write]}"
          end

          files = report("list_io_parallel_specs", args, tree).lines.size
          "dry run, would write #{files} spec files to #{args[:write]} (add --confirm)"
        end
      end
    end
  end
end
