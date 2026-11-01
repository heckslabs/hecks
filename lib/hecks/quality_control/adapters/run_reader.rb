# frozen_string_literal: true

require "json"
require "open3"
require "time"
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
      FAILED_EXAMPLE = %r{rspec (\./spec/\S+?\.rb)(?:\[[^\]]*\]|:\d+)\s*#?\s*(.*)$}

      # The `.rb` ending of a spec path, left off its key.
      RUBY_SUFFIX = ".rb"

      # Runs of characters a Work key does not hold.
      KEY_BREAK = /[^a-zA-Z0-9_]+/

      # A job whose name says it runs specs.
      SPEC_JOB = /spec/i

      # Job conclusions that mean a job ran its specs to the end.
      RAN = %w[success failure].freeze

      # Longest text the reader keeps of a failure line or the example list.
      SHORT = 200

      # @param aggregate [Object, nil] unused
      # @param settings [Hash] unused
      # @param root [String, nil] the checkout `gh` runs in; this repository when nil
      def initialize(aggregate: nil, settings: {}, root: nil)
        @root = root || File.expand_path("../../../..", __dir__)
      end

      # @param run [Hash, String] the GitHub run id
      # @param repo [Hash, String] `owner/name`
      # @return [Hash] `commit:` and `settled:` ("yes" when the run's spec jobs ran to the end)
      def read(run:, repo:, **)
        id = named(run)
        view = JSON.parse(gh("run", "view", id, "--repo", named(repo), "--json", "headSha,conclusion,jobs"))
        failures = failures_in(gh("run", "view", id, "--repo", named(repo), "--log-failed"))
        failures.each { |path, examples| report(path, examples, id, view.fetch("headSha")) }
        { commit: { value: view.fetch("headSha") }, settled: { value: settled?(view) ? "yes" : "no" } }
      end

      private

      def named(value) = value.is_a?(Hash) ? value.values.first.to_s : value.to_s

      # Every job that runs specs has ended in a pass or a fail, and at least one did.
      def settled?(view)
        spec_jobs = view.fetch("jobs", []).select { |job| job["name"].to_s.match?(SPEC_JOB) }
        spec_jobs.any? && spec_jobs.all? { |job| RAN.include?(job["conclusion"]) }
      end

      # @return [Hash{String => Array<String>}] each failing spec file to its failing example texts
      def failures_in(log)
        log.each_line(chomp: true).with_object(Hash.new { |h, k| h[k] = [] }) do |line, found|
          match = FAILED_EXAMPLE.match(line)
          found[match[1].delete_prefix("./")] << match[2].strip if match
        end
      end

      def report(path, examples, run, commit)
        key = "red-#{path.delete_suffix(RUBY_SUFFIX).gsub(KEY_BREAK, "-").downcase}"
        facts = facts_of(examples, run, commit)
        if red?(key)
          dispatch("QualityControl::RedSpec.Update", facts.merge(to: key))
        else
          dispatch("QualityControl::RedSpec.Open", facts.merge(spec: key, path: path, title: "#{path} is red on main",
                                                               since: Time.now.utc.strftime("%Y-%m-%d")))
        end
      end

      def facts_of(examples, run, commit)
        count = examples.size
        { failures: count, first_failure: short(examples.first.to_s), examples: short(examples.first(3).join(" | ")),
          last_run: run, commit: commit,
          detail: short("#{count} failing example#{"s" unless count == 1}; first: #{examples.first}; run #{run}; sha #{commit}") }
      end

      def short(text) = text.length > SHORT ? "#{text[0, SHORT - 3]}..." : text

      # Whether the spec's row is red now: a red row is updated, a green or absent one is opened.
      def red?(key)
        sweep = Runtime::RowSweep.new(registry)
        aggregate = sweep.query_aggregate("QualityControl", "RedSpec", verb: "RedSpec.OnMain")
        sweep.rows("QualityControl", aggregate, "OnMain", {}).any? { |row| row[:id].to_s == key }
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
