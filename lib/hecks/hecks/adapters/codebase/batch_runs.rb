# frozen_string_literal: true

require_relative "spec_files"
require_relative "impacted_specs"
require_relative "run_options"
require_relative "test_runner"
require_relative "heavy_slots"

module Hecks
  module Adapters
    module Codebase
      # What Codebase's `TestSuiteRun` asks to run by file: one example of one file, several
      # files in one launcher boot, and the files a branch's changes touch.
      module BatchRuns
        # The operations this module carries out.
        OPERATIONS = %w[run_spec_example run_spec_files run_impacted_specs].freeze

        # The heavy-job class a run of several files takes a place as ({HeavySlots}); one example
        # is light and takes none.
        JOB = "spec_batch"

        module_function

        # @param operation [String] one of `OPERATIONS`
        # @param args [Hash] the `TestSuiteRun` record's plain fields
        # @param tree [Tree] the checkout
        # @return [String] each file's counts and the total, with the mapping for an impacted run
        # @raise [ConsoleCapture::Failure] when a file fails or cannot be run
        def call(operation, args, tree)
          case operation
          when "run_spec_example" then spec_example(args, tree)
          when "run_spec_files" then spec_files(args, tree)
          else impacted(args, tree)
          end
        end

        # @param args [Hash] `file`, `example`, and the arguments that set the specs' variables
        # @param tree [Tree] the checkout
        # @return [String] what the runner printed
        def spec_example(args, tree)
          TestRunner.new(tree).run(file: args[:file], example: args[:example], env: RunOptions.spec_env(args), tags: args[:tags])
        end

        # @param args [Hash] `files` (whitespace-separated), `example`, `isolation` and the
        #   run's variables
        # @param tree [Tree] the checkout
        # @return [String] each file's counts and the total
        def spec_files(args, tree)
          HeavySlots.admitted(tree.root, JOB) do
            SpecFiles.new(tree).run(files: args[:files], example: args[:example], isolation: args[:isolation] || "process",
                                    env: RunOptions.spec_env(args), tags: args[:tags])
          end
        end

        # @param args [Hash] `base` (`main` when absent), `cap`, `dry`, `isolation`, `example`
        #   and the run's variables
        # @param tree [Tree] the checkout
        # @return [String] the mapping and, unless dry, how each spec file ended
        def impacted(args, tree)
          HeavySlots.admitted(tree.root, JOB) do
            ImpactedSpecs.new(tree).call(base: args[:base] || "main", cap: args[:cap] || ImpactedSpecs::DEFAULT_CAP,
                                         dry: args[:dry] == true, isolation: args[:isolation] || "process",
                                         example: args[:example], env: RunOptions.spec_env(args), tags: args[:tags])
          end
        end
      end
    end
  end
end
