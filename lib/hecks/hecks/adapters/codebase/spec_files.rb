# frozen_string_literal: true

require_relative "tree"
require_relative "test_runner"
require_relative "spec_files/report"
require_relative "spec_files/shared_run"
require_relative "../console_capture"

module Hecks
  module Adapters
    module Codebase
      # Several spec files run in one launcher boot, and how each ended.
      #
      # `process` isolation gives every file a new process of its own, so nothing one file defines,
      # stubs or registers reaches the next: it saves the launcher's boot, not each file's load.
      # `shared` isolation runs every file in one test-runner process, the fastest, and may expose
      # an order dependence between files (constants, stubs, Memory registries are shared).
      #
      # The report names each file with its example and failure counts, and ends with the total
      # counts as the test runner spells them. A run in which any file failed is refused with it.
      class SpecFiles
        # Every way the files can be isolated; the first is the default.
        ISOLATIONS = %w[process shared].freeze

        # The example filter that matches every example.
        ALL_EXAMPLES = " "

        COUNTS = /(\d+) examples?, (\d+) failures?/

        # @param tree [Tree] the checkout whose specs are run
        # @param runner [TestRunner] runs the test runner on arguments
        def initialize(tree, runner: TestRunner.new(tree))
          @tree = tree
          @runner = runner
        end

        # @param files [String, Array<String>] spec files, relative to the checkout or absolute; a
        #   string is split on whitespace
        # @param example [String, nil] part of an example's description; every example when nil
        # @param isolation [String] one of `ISOLATIONS`
        # @param env [Hash{String => String}] variables the specs read, set for these runs only
        # @param tags [String, nil] RSpec tag filters as the runner spells them
        # @return [String] the per-file counts and the total, when every file passed
        # @raise [ConsoleCapture::Failure] naming the files that failed, or that are not there
        def run(files:, example: nil, isolation: "process", env: {}, tags: nil)
          names = Array(files).flat_map { |name| name.to_s.split }.uniq
          check(names, isolation)
          report = isolate(isolation, names, filters(example, tags), env)
          raise ConsoleCapture::Failure, report.to_s if report.failed?

          report.to_s
        end

        private

        # A single space matches every example, and a named example overrides the tag exclusions
        # (`:io`, `:process`, `:fuzzing`) as a one-file run does, so an absent filter is that space.
        def filters(example, tags) = ["--example", example.to_s.empty? ? ALL_EXAMPLES : example, *tags.to_s.split]

        def isolate(isolation, names, options, env)
          isolation == "shared" ? shared(names, options, env) : fresh(names, options, env)
        end

        def check(names, isolation)
          raise ConsoleCapture::Failure, "no spec files named" if names.empty?
          unless ISOLATIONS.include?(isolation)
            raise ConsoleCapture::Failure, "isolation is process or shared, not #{isolation.inspect}"
          end

          missing = names.reject { |name| File.file?(File.expand_path(name, @tree.root)) }
          raise ConsoleCapture::Failure, "no such spec file #{missing.join(" ")}" unless missing.empty?
        end

        def fresh(names, options, env)
          endings = names.map do |name|
            status, printed = @runner.outcome([*options, name], env: env, fresh: true)
            examples, failures = counts(printed)
            Ending.new(name, examples, failures, !status.zero?, printed)
          end
          Report.new(endings, "process")
        end

        def shared(names, options, env)
          endings, printed = SharedRun.new(@tree, @runner).call(names, options, env)
          Report.new(endings, "shared", printed: printed)
        end

        def counts(printed)
          found = printed.match(COUNTS)
          found ? [found[1].to_i, found[2].to_i] : [0, 0]
        end
      end
    end
  end
end
