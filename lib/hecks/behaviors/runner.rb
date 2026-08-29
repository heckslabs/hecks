require_relative "expectations"

# Hecks::Behaviors.run(path) / .run_all(dir)
#
# Discovery + aggregation. `run_one` (expectations.rb) is the impure edge
# that actually touches a live runtime; this file finds `.behaviors`
# files, loads them, and maps their tests through it.
module Hecks
  # See this file's own header above for `.run`/`.run_all`/`.parse` — the
  # discovery-and-aggregation half of the `.behaviors` authoring surface;
  # `Expectations` (expectations.rb) is the impure edge that actually runs
  # one test against a live runtime.
  module Behaviors
    FileResult = Struct.new(:path, :parse_error, :runs, keyword_init: true)
    SweepResult = Struct.new(:root, :files_swept, :files, :summary, keyword_init: true)
    ParseResult = Struct.new(:path, :suite, :parse_error, keyword_init: true)

    class LoadOutsideRunner < StandardError; end

    class << self
      # The `.behaviors` file currently being `Kernel.load`ed, if any —
      # bound only for the duration of that load (`run`'s own `ensure`),
      # never left set. `Hecks.behaviors` (lib/hecks/behaviors.rb)
      # reads this to resolve its own `loads` line relative to the right
      # file, and to refuse a `.behaviors` file loaded any other way.
      attr_accessor :loading_path

      # The suite the most recent `Hecks.behaviors` call built — read
      # once, right after `Kernel.load`, by `run` below, which resets it
      # to nil before every load so a file that loads without calling
      # `Hecks.behaviors` at all is never confused for a stale previous
      # suite (a real bug in a prior port of this idea: compared only
      # against nil, so after the first successful file in a sweep it
      # stayed non-nil forever).
      attr_accessor :last_suite

      # `Kernel.load`s one `.behaviors` file and returns its suite, with
      # NO test actually executed yet — the cheap half, split out so a
      # caller that only needs to know what tests exist (the rspec shim,
      # naming its `it`s at collection time) doesn't pay for running them
      # until it actually wants to. `Behaviors.loading_path` is bound only
      # for the duration of the load, and `last_suite` is reset to nil
      # BEFORE it — a file that loads without ever calling
      # `Hecks.behaviors` is unambiguously a parse error, never a stale
      # suite from whatever loaded before it in a sweep (a real bug in a
      # prior port of this idea: compared only against nil, so after the
      # first successful file in a sweep it stayed non-nil forever).
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
      def run(path)
        parsed = parse(path)
        return FileResult.new(path: parsed.path, parse_error: parsed.parse_error, runs: []) if parsed.parse_error

        runs = parsed.suite.tests.map { |test| Expectations.run_one(test, parsed.suite) }
        FileResult.new(path: parsed.path, parse_error: nil, runs: runs)
      end

      # Sweeps every `.behaviors` file under `dir`. Reports the file count
      # it actually found — a sweep that goes green without saying how
      # much it looked at is indistinguishable from one that found
      # nothing to look at.
      def run_all(dir)
        files = Dir.glob(File.join(dir, "**", "*.behaviors"))
        results = files.map { |path| run(path) }
        SweepResult.new(root: dir, files_swept: files.size, files: results, summary: summarize(results))
      end

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
