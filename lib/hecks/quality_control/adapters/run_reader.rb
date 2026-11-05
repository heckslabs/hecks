# frozen_string_literal: true

require "json"
require "open3"
require "time"
require "hecks/quality_control/adapters/run_keys"
require "hecks/runtime/asking"
require "hecks/runtime/errors"
require "hecks/runtime/row_sweep"
require "hecks/runtime/dispatcher"

module Hecks
  module Adapters
    # The `Reader` port's adapter: reads one CI run of main (`gh run view`, job logs) for the spec
    # files it failed, and reports each to `RedSpec` through the boot whose `MainRun` asked. A file
    # already red is updated, never opened twice. It answers the commit and whether the run settled,
    # which the bluebook's policies use to clear the files the run did not fail.
    #
    # `gh` is the one thing it reaches for besides the clock; a spec stubs `Open3` with a fake run.
    class RunReader
      # A line of RSpec's "Failed examples:" summary as a job log prints it: the file, then the
      # example's description.
      # The path is read up to its `.rb` and the location that follows (`:12` or `[1:2]`), so a
      # path with a space in it still matches; RSpec may quote it or escape the space.
      FAILED_EXAMPLE = %r{rspec ['"]?(\./spec/.+?\.rb)(?:\[[^\]]*\]|:\d+)['"]?\s*(?:#\s*(.*))?$}

      # Where a path's escaped space is unescaped.
      ESCAPED_SPACE = "\\ "

      # A job whose name says it runs specs.
      SPEC_JOB = /spec/i

      # The branch and the event whose runs count: a push to main.
      BRANCH = "main"
      EVENT = "push"

      # What `gh run view --json` is asked for.
      JSON_FIELDS = "headSha,headBranch,event,createdAt,conclusion,jobs"

      # Longest text the reader keeps of a failure line or the example list.
      SHORT = 200

      # @param aggregate [Object, nil] unused
      # @param settings [Hash] unused
      # @param root [String, nil] the checkout `gh` runs in; this repository when nil
      def initialize(aggregate: nil, settings: {}, root: nil)
        @root = root || File.expand_path("../../../..", __dir__)
      end

      # @param path [String] a spec path such as `spec/a/b_spec.rb`
      # @return [String] the key of its row; see `RunKeys`
      def self.key_for(path) = RunKeys.spec(path)

      # @param run [Hash, String] the GitHub run id
      # @param repo [Hash, String] `owner/name`
      # @return [Hash] `commit:` and `settled:` ("yes" only when every spec job ended `success`)
      # @raise [Runtime::GivenNotMet] when the run is not a push to main
      def read(run:, repo:, **)
        id = named(run)
        view = JSON.parse(gh("run", "view", id, "--repo", named(repo), "--json", JSON_FIELDS))
        refuse_unless_main!(view, id)
        seen = { run: id, commit: view.fetch("headSha") }
        file_failures(failures_in(gh("run", "view", id, "--repo", named(repo), "--log-failed")), view, seen)
        { commit: { value: seen[:commit] }, settled: { value: green?(view, id) ? "yes" : "no" } }
      end

      private

      def green?(view, id) = settled?(view) && !behind_a_row?(id)

      # Reports each failing file; a failed job whose log named none is reported as a row
      # of its own.
      def file_failures(failures, view, seen)
        failures.each { |path, examples| report(RunKeys.spec(path), path, examples, seen) }
        report_unparsed(view, failures, seen)
      end

      def named(value) = value.is_a?(Hash) ? value.values.first.to_s : value.to_s

      # Only a push to main is read: another branch's run, or a pull request's, says nothing
      # of main.
      def refuse_unless_main!(view, id)
        return if view["headBranch"] == BRANCH && view["event"] == EVENT

        raise Runtime::GivenNotMet, "run #{id} is #{view["event"].inspect} on #{view["headBranch"].inspect}, " \
                                    "not a #{EVENT} to #{BRANCH}; only main's own runs are read"
      end

      def spec_jobs(view) = view.fetch("jobs", []).select { |job| job["name"].to_s.match?(SPEC_JOB) }

      # Every job that runs specs ended `success`, and at least one did. A failed job with no
      # failure parsed from its log is not green: the run clears nothing.
      def settled?(view)
        jobs = spec_jobs(view)
        jobs.any? && jobs.all? { |job| Hecks::CheckConclusion.evidence?(job["conclusion"]) }
      end

      # @param conclusion [String, nil] a spec job's conclusion
      # @return [Boolean] whether the job already has a verdict on the specs, passed or unfinished
      def evidence_or_unfinished?(conclusion)
        Hecks::CheckConclusion.evidence?(conclusion) || Hecks::CheckConclusion.unfinished?(conclusion)
      end

      # A spec job that failed (or timed out) while the log named no failing example is reported as
      # a row of its own, so the failure stays visible and open.
      def report_unparsed(view, failures, seen)
        return unless failures.empty?

        spec_jobs(view).reject { |job| evidence_or_unfinished?(job["conclusion"]) }.each do |job|
          name = job["name"].to_s
          report(RunKeys.job(name), "job #{name}", ["#{name} #{job["conclusion"]}: no failing example in its log"], seen,
                 title: "spec job #{name} failed on main with no failing example parsed")
        end
      end

      # @return [Hash{String => Array<String>}] each failing spec file to its failing example texts
      def failures_in(log)
        log.each_line(chomp: true).with_object(Hash.new { |h, k| h[k] = [] }) do |line, found|
          match = FAILED_EXAMPLE.match(line)
          found[match[1].delete_prefix("./").gsub(ESCAPED_SPACE, " ")] << match[2].to_s.strip if match
        end
      end

      def report(key, path, examples, seen, title: "#{path} is red on main")
        facts = facts_of(examples, seen[:run], seen[:commit])
        row = row_for(key)
        if row
          dispatch("QualityControl::RedSpec.Update", facts.merge(to: key)) unless older?(seen[:run], row)
        else
          open_or_reopen(key, path, title, facts)
        end
      end

      # A file never seen red is opened; one cleared earlier already has its row, which reopens.
      def open_or_reopen(key, path, title, facts)
        facts = facts.merge(title: title, since: Time.now.utc.strftime("%Y-%m-%d"))
        dispatch("QualityControl::RedSpec.Open", facts.merge(spec: key, path: path))
      rescue Runtime::AlreadyExists
        dispatch("QualityControl::RedSpec.Reopen", facts.merge(to: key))
      end

      # A run older than the one the row last saw does not overwrite what the row knows.
      def older?(run, row) = run.to_i < last_run_of(row)

      def last_run_of(row)
        value = row[:last_run]
        (value.respond_to?(:value) ? value.value : value).to_s.to_i
      end

      # Whether some red row was last seen by a newer run than this one: GitHub run ids grow, so a
      # run behind a row says nothing of the file's state now and clears nothing.
      def behind_a_row?(run) = open_rows.any? { |row| last_run_of(row) > run.to_i }

      def facts_of(examples, run, commit)
        count = examples.size
        { failures: count, first_failure: short(examples.first.to_s), examples: short(examples.first(3).join(" | ")),
          last_run: run, commit: commit,
          detail: short("#{count} failing example#{"s" unless count == 1}; first: #{examples.first}; run #{run}; sha #{commit}") }
      end

      def short(text) = text.length > SHORT ? "#{text[0, SHORT - 3]}..." : text

      # The spec's row while it is red: a red row is updated, a green or absent one is opened.
      def row_for(key) = open_rows.find { |row| row[:id].to_s == key }

      def open_rows
        sweep = Runtime::RowSweep.new(registry)
        aggregate = sweep.query_aggregate("QualityControl", "RedSpec", verb: "RedSpec.OnMain")
        sweep.rows("QualityControl", aggregate, "OnMain", {})
      end

      def dispatch(verb, args) = Runtime::Dispatcher.new(registry).dispatch_flat(verb, args)

      def registry
        Runtime::Asking.registry or raise Runtime::GivenNotMet, "a run is read only when its MainRun asks"
      end

      def gh(*args)
        out, err, status = Open3.capture3("gh", *args, chdir: @root)
        raise Runtime::GivenNotMet, "gh #{args.first(3).join(" ")} failed: #{err.lines.first&.strip}" unless status.success?

        out
      rescue Errno::ENOENT
        raise Runtime::GivenNotMet, "gh is not installed or not on PATH"
      end
    end
  end
end
