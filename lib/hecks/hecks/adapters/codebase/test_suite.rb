# frozen_string_literal: true

require "fileutils"
require_relative "tree"
require_relative "minitest_runs"
require_relative "run_options"
require_relative "test_runner"
require_relative "changed_specs"
require_relative "batch_runs"
require_relative "sqlite_fixture"
require_relative "cargo_tests"
require_relative "cache_clearing"
require_relative "test_suite/pattern_cases"
require_relative "test_suite/spec_shards"
require_relative "test_suite/io_parallel_specs"
require_relative "test_suite/stress_run"

module Hecks
  module Adapters
    module Codebase
      # What Codebase's `TestSuiteRun` asks of the working tree: the tooling around this
      # repository's specs.
      #
      # Each ask calls the module beside it that does the work and answers its value: the stress
      # run, the semantics seeding, the spec shards, the io-parallel listing and the pattern cases;
      # a single example goes to the `TestRunner` adapter and the persistence fixtures to the
      # `SqliteFixture` adapter. A listing is a pure read.
      # Regenerating the fixtures and writing the committed spec list change tracked files, so
      # unconfirmed they report what they would do and write nothing.
      module TestSuite
        # Every operation this family carries out.
        OPERATIONS = %w[run_spec_example run_spec_files run_impacted_specs run_suite run_changed
                        stress_concurrency run_cargo_tests clear_caches regenerate_legacy_fixtures seed_semantics_corpus
                        write_io_parallel_spec_list rewrite_ir_golden].freeze

        # The operations that run specs in a folder of their own: they need that folder to hold
        # specs, not to be this checkout, so any project's suite runs through them.
        FOLDER_OPERATIONS = %w[run_spec_example run_spec_files run_impacted_specs run_suite run_changed].freeze

        # The spec directory a folder's whole suite lives in.
        SPEC_DIRECTORY = "spec"

        # The spec that pins the frozen IR of the language bluebooks.
        GOLDEN_SPEC = "spec/ir_golden_spec.rb"

        # The tag filter the postgres job lists its specs by when none is named.
        DEFAULT_TAGS = "--tag io --tag ~fuzzing"

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
          when *BatchRuns::OPERATIONS then BatchRuns.call(operation, args, tree)
          when "run_suite" then suite(args, tree)
          when "run_changed" then changed(args, tree)
          when "run_cargo_tests" then CargoTests.run(args, tree, shell)
          when "clear_caches" then CacheClearing.clear
          else tooling(operation, args, tree, shell)
          end
        end

        # The operations that run one of the repository's own tools.
        #
        # @param operation [String] one of `OPERATIONS`
        # @return [String] what the tool printed
        def tooling(operation, args, tree, shell)
          case operation
          when "stress_concurrency" then stress(args, tree)
          when "regenerate_legacy_fixtures" then regenerate_fixtures(args, tree, shell)
          when "seed_semantics_corpus" then seed(args, tree)
          when "rewrite_ir_golden" then rewrite_golden(args, tree)
          else write_list(args, tree)
          end
        end

        # Runs every spec of the folder's spec directory in one process.
        #
        # @param args [Hash] `tags`, `strict`, `seeds` and `environment`, each perhaps absent
        # @param tree [Tree] the folder whose specs run
        # @return [String] what the runner printed
        def suite(args, tree)
          rspec = TestRunner.new(tree).run_paths(paths: [SPEC_DIRECTORY], env: RunOptions.spec_env(args), tags: args[:tags])
          minitest = MinitestRuns.files(tree)
          return rspec if minitest.empty?

          ([rspec] + MinitestRuns.reports(tree, minitest)).join("\n")
        end

        # Runs the specs the files changed since a git ref map to, by name. Says so and runs nothing
        # when no spec maps to a change, so an unmapped change never falls back to the whole suite.
        #
        # @param args [Hash] `base` (the ref, `origin/main` when absent), and the run's variables
        # @param tree [Tree] the folder whose changes are read
        # @return [String] what the runner printed, or that no spec maps to the changes
        # @raise [ConsoleCapture::Failure] when git cannot read the changes
        def changed(args, tree)
          base = args[:base] || "origin/main"
          files = ChangedSpecs.changed_files(tree, base)
          specs = Dir.glob("#{SPEC_DIRECTORY}/**/*_spec.rb", base: tree.root).sort
          mapped = ChangedSpecs.call(files, specs)
          return "no spec maps to the #{files.size} changed file(s) since #{base}; nothing run" if mapped.empty?

          TestRunner.new(tree).run_paths(paths: mapped, env: RunOptions.spec_env(args), tags: args[:tags])
        end

        # @param args [Hash] `runs`, `parallel` and `seed_start`
        # @param tree [Tree] the checkout
        # @return [String] what ran and the clean verdict
        # @raise [ConsoleCapture::Failure] on flakiness, or when the run count or first seed is
        #   missing
        def stress(args, tree)
          counts = %i[runs seed_start parallel].to_h { |name| [name, args[name] && Integer(args[name])] }.compact
          missing = %i[runs seed_start] - counts.keys
          raise ConsoleCapture::Failure, "a stress run needs #{missing.join(" and ")}" unless missing.empty?

          StressRun.call(root: tree.root, **counts)
        end

        # @param args [Hash] `confirm`
        # @param tree [Tree] the checkout
        # @param shell [#capture, nil] starts the fixtures' child process
        # @return [String] what was regenerated, or (unconfirmed) what would be
        def regenerate_fixtures(args, tree, shell)
          SqliteFixture.new(tree, shell: shell).regenerate(confirm: args[:confirm] == true)
        end

        # Seeds at reaction depth zero, as a plain run would: the replay's sagas cascade, and the
        # launching command's own cascade would otherwise cut them short.
        #
        # @param args [Hash] `fixture`, perhaps absent
        # @param tree [Tree] the checkout
        # @return [String] the fixtures seeded, or that there was nothing to seed
        def seed(args, tree)
          require_relative "test_suite/semantics_seeding"
          TestRunner.at_reaction_depth_zero { SemanticsSeeding.call(root: tree.root, only: args[:fixture]) }
        end

        # Rewrites the frozen IR files by running the golden spec with `GOLDEN=rewrite`. Unconfirmed
        # it writes nothing and says so; read the diff of `spec/golden/ir` afterwards.
        #
        # @param args [Hash] `confirm`
        # @param tree [Tree] the checkout
        # @return [String] what the spec run printed, or (unconfirmed) what would be rewritten
        def rewrite_golden(args, tree)
          return "dry run, would rewrite spec/golden/ir from #{GOLDEN_SPEC} (add --confirm)" unless args[:confirm] == true

          TestRunner.new(tree).run_paths(paths: [GOLDEN_SPEC], env: { "GOLDEN" => "rewrite" }, tags: nil)
        end

        # A pure read: a listing, or the recorded pattern cases.
        #
        # @param operation [String] `shard_specs`, `list_io_parallel_specs`, `record_pattern_cases`
        # @param args [Hash] the query's plain arguments
        # @param tree [Tree] the checkout
        # @param shell [#capture, nil] unused: every listing is read in this process
        # @return [String] the listing, one item per line, or the pattern cases as JSON
        # @raise [ConsoleCapture::Failure] when the arguments are refused or a committed list is
        #   stale
        def report(operation, args, tree, shell: nil)
          case operation
          when "shard_specs" then shards(args, tree).join("\n")
          when "list_io_parallel_specs" then io_parallel(args, tree).join("\n")
          else PatternCases.json
          end
        end

        # @param args [Hash] `group`, `groups` and `runtime_log`
        # @param tree [Tree] the checkout
        # @return [Array<String>] the group's spec files
        def shards(args, tree)
          SpecShards.files(root: tree.root, group: Integer(args[:group]), groups: Integer(args[:groups]),
                           runtime_log: args[:runtime_log])
        end

        # @param args [Hash] `exclude`, `tags` and `check`
        # @param tree [Tree] the checkout
        # @return [Array<String>] the files that carry a matching example
        def io_parallel(args, tree)
          listing = io_listing(args, tree)
          args[:check] ? IoParallelSpecs.check(listing, args[:check]) : IoParallelSpecs.files(listing)
        end

        # @param args [Hash] `exclude` and `tags`
        # @param tree [Tree] the checkout
        # @return [IoParallelSpecs::Listing] the checkout, exclude pattern and tag words
        def io_listing(args, tree)
          IoParallelSpecs::Listing.new(root: tree.root, exclude: args[:exclude].to_s, tags: tag_words(args))
        end

        # @param held [Hash] the record's fields, each perhaps a value object's `{ value: x }`
        # @return [Hash] the same fields as plain values
        def plain(held) = held.transform_values { |value| value.is_a?(Hash) ? value[:value] : value }

        # @param args [Hash] `tags`, perhaps absent
        # @return [Array<String>] the tag filter, one word each
        def tag_words(args) = (args[:tags] || DEFAULT_TAGS).split

        # @param args [Hash] `exclude`, `tags`, `write` and `confirm`
        # @param tree [Tree] the checkout whose spec list is written
        # @return [String] what was written, or (unconfirmed) how many files would be
        # @raise [ConsoleCapture::Failure] when the listing is refused
        def write_list(args, tree)
          unless args[:confirm] == true
            return "dry run, would write #{io_parallel(args, tree).size} spec files to #{args[:write]} (add --confirm)"
          end

          IoParallelSpecs.write(io_listing(args, tree), args[:write])
          "wrote #{args[:write]}"
        end
      end
    end
  end
end
