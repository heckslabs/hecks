require_relative "expectations"

# Hecks::Behaviors.run(path) / .run_all(dir)
#
# Finds `.behaviors` files, loads them, and runs their tests through `Expectations.run_one`.
module Hecks
  # The `.behaviors` toolkit: DSL, IR, runner and rspec shim.
  module Behaviors
    FileResult = Struct.new(:path, :parse_error, :runs, keyword_init: true)
    SweepResult = Struct.new(:root, :files_swept, :files, :summary, keyword_init: true)
    ParseResult = Struct.new(:path, :suite, :parse_error, keyword_init: true)

    class LoadOutsideRunner < StandardError; end

    class << self
      # The `.behaviors` file being `Kernel.load`ed; `Hecks.behaviors` reads it to resolve
      # `loads` and to refuse a file loaded any other way.
      attr_accessor :loading_path

      # The suite the latest `Hecks.behaviors` call built. `parse` resets it before each load so
      # a file that never calls `Hecks.behaviors` is not mistaken for the previous suite.
      attr_accessor :last_suite

      # `Kernel.load`s one `.behaviors` file and returns its suite without running any test.
      #
      # @param path [String] the `.behaviors` file's path
      # @return [Behaviors::ParseResult] `suite` holding the built `BehaviorsSuite` and
      #   `parse_error` nil on success; `suite` nil and `parse_error` a String describing
      #   a raised exception, or the file loading without calling `Hecks.behaviors`
      def parse(path)
        path = File.expand_path(path)
        previous_path = loading_path
        self.loading_path = path
        self.last_suite = nil

        begin
          Kernel.load(path)
        rescue StandardError, ScriptError => e
          return ParseResult.new(path: path, suite: nil, parse_error: "#{e.class}: #{e.message}")
        ensure
          self.loading_path = previous_path
        end

        suite = last_suite
        return ParseResult.new(path: path, suite: nil, parse_error: "file loaded but called no Hecks.behaviors") unless suite

        ParseResult.new(path: path, suite: suite, parse_error: nil)
      end

      # One `.behaviors` file → `FileResult`, every test actually run.
      #
      # @param path [String] the `.behaviors` file's path
      # @return [Behaviors::FileResult] `parse_error` and empty `runs` on a parse
      #   failure; otherwise `parse_error` nil and `runs` one `Expectations::Result`
      #   per test
      def run(path)
        parsed = parse(path)
        return FileResult.new(path: parsed.path, parse_error: parsed.parse_error, runs: []) if parsed.parse_error

        runs = parsed.suite.tests.map { |test| Expectations.run_one(test, parsed.suite) }
        FileResult.new(path: parsed.path, parse_error: nil, runs: runs)
      end

      # Sweeps every `.behaviors` file under `dir`, reporting the file count so a green sweep
      # that found nothing is distinguishable.
      #
      # @param dir [String] the directory to search, recursively, for `.behaviors` files
      # @return [Behaviors::SweepResult] `files_swept` the count found, `files` one
      #   `FileResult` per file, and `summary` the aggregate counts `summarize` returns
      def run_all(dir)
        files = Dir.glob(File.join(dir, "**", "*.behaviors"))
        results = files.map { |path| run(path) }
        SweepResult.new(root: dir, files_swept: files.size, files: results, summary: summarize(results))
      end

      # Tallies a sweep's results into counts by outcome.
      #
      # @param results [Array<Behaviors::FileResult>] the swept files' results
      # @return [Hash{Symbol => Integer}] `:files` the file count, `:parse_errors` files
      #   that failed to parse, `:total` tests actually run across every file, `:passed`,
      #   `:failed` and `:errored` counting each `Expectations::Result#status`
      def summarize(results)
        runs = results.flat_map(&:runs)
        {
          files:        results.size,
          parse_errors: results.count(&:parse_error),
          total:        runs.size,
          passed:       runs.count { |r| r.status == :pass },
          failed:       runs.count { |r| r.status == :fail },
          errored:      runs.count { |r| r.status == :error }
        }
      end
    end
  end
end
