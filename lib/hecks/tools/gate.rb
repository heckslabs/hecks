# frozen_string_literal: true

require "open3"
require "hecks/vocabulary"
require_relative "../tools"
require_relative "../rust_build/gate_build"
require_relative "stage_progress"
require_relative "gate_memo/session"
require_relative "gate_report"

module Hecks
  module Tools
    # Runs a stage's checks, which the `GateStage` and `GateCheck` rows of the Vocabulary bluebook
    # hold as data, all at once and reports every one, so a red check does not hide the others.
    #
    #   hecks gate pre_push                # every check of the stage
    #   hecks gate pre_push only=rubocop   # the named checks
    #   hecks gate --list                  # the stages and their checks
    #
    # A green stage prints which checks passed; a red one prints each failing check's whole output
    # and what its failure means, and answers status 1. A check whose inputs are unchanged since its
    # last green run is not run: it is printed as skipped, and the verdict counts it as skipped, not
    # passed (see GateMemo).
    module Gate
      USAGE = "usage: hecks gate <stage> [only=a,b] | hecks gate --list"

      # RuboCop keys its cache by file content, so one directory shared by every worktree lets each
      # reuse the others' results. It is set here, in the gate's child environment, and not in
      # .rubocop.yml, so CI and a bare `rubocop` keep the defaults (ADR 0091).
      RUBOCOP_CACHE_ROOT = File.join(Dir.home, ".cache", "hecks", "rubocop")

      module_function

      # @return [Hash{String => Hash}] each stage by name: its `env` and its `checks`, in order,
      #   each check with its `id`, `title`, `run` words and `blocked`
      def stages
        checks = Vocabulary.rows("GateCheck").to_h { |row| [row["name"], check(row)] }
        Vocabulary.rows("GateStage").to_h do |row|
          stage = { "env" => env(row["env"]), "checks" => row["checks"].split(",").map { |name| checks.fetch(name) } }
          [row["name"], stage]
        end
      end

      # @param row [Hash{String => String}] a `GateCheck` row
      # @return [Hash] the check: a script runs as `sh -ec`, otherwise `argv` is the command's words
      def check(row)
        run = row["script"].empty? ? row["argv"].split : ["sh", "-ec", row["script"]]
        row.slice("id", "title", "blocked").merge("run" => run)
      end

      # @param words [String] `NAME=value` words
      # @return [Hash{String => String}] the variables a stage sets
      def env(words)
        words.split.to_h { |word| word.split("=", 2) }
      end

      # @param argv [Array<String>] a stage name and optionally `only=a,b`, or `--list`
      # @param root [String] the checkout the checks run in
      # @param progress [StageProgress] where each check's start and end lines go
      # @return [Integer] 0 when every check passed, 1 when one failed, 2 on bad usage
      def main(argv, root: Tools::ROOT, progress: StageProgress.new, **)
        stages = self.stages
        return list(stages) if argv == ["--list"]

        name, only = parse(argv)
        stage = stages[name]
        return usage(stages, name) unless stage

        checks = select(stage.fetch("checks"), only)
        return unknown(stage, only) if checks.nil?

        run_planned(name, stage, checks, root, progress)
      end

      # Runs the checks the memo does not skip, records the green ones, and reports the stage.
      #
      # @return [Integer] the verdict of `report`
      def run_planned(name, stage, checks, root, progress)
        session = GateMemo::Session.new(root: root, env: stage.fetch("env", {}))
        plan = session.plan(checks)
        results = run_all(stage, plan.run, root, progress)
        # Every selected check must come back with a result, ran or skipped as unchanged; the
        # counts say so for the GateRun record to check.
        puts "gate-counts expected=#{checks.size} recorded=#{results.size + plan.skipped.size}"
        GateReport.report(name, plan, results, session.record(results))
      end

      # @param argv [Array<String>] the command line words
      # @return [Array(String, Array<String>)] the stage name and the check ids named by `only=`
      def parse(argv)
        name = argv.find { |arg| !arg.include?("=") && !arg.start_with?("--") }
        only = argv.filter_map { |arg| arg.delete_prefix("only=").split(",") if arg.start_with?("only=") }.flatten
        [name, only]
      end

      # @param checks [Array<Hash>] a stage's checks
      # @param only [Array<String>] the check ids asked for; every check when empty
      # @return [Array<Hash>, nil] the checks to run, nil when an id names no check
      def select(checks, only)
        return checks if only.empty?
        return nil unless (only - checks.map { |check| check["id"] }).empty?

        checks.select { |check| only.include?(check["id"]) }
      end

      # Starts every check at once and waits for all of them.
      #
      # @param stage [Hash] the stage: its `env` and `checks`
      # @param checks [Array<Hash>] the checks to run
      # @param root [String] the directory they run in
      # @param progress [StageProgress] told when each check starts and ends
      # @return [Hash{String => Array}] each check's id, and its output and whether it passed
      def run_all(stage, checks, root, progress)
        env = stage.fetch("env", {}).reject { |key, _| ENV.key?(key) }
        threads = checks.map do |check|
          progress.start(check["id"])
          Thread.new { [check["id"], run_timed(check, env, root, progress)] }
        end
        threads.to_h(&:value)
      end

      # @return [Array(String, Boolean)] what the check printed, and whether it exited 0; the end
      #   line is written as the check finishes
      def run_timed(check, env, root, progress)
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        output, passed = run_one(check, env, root)
        progress.finish(check["id"], passed, Process.clock_gettime(Process::CLOCK_MONOTONIC) - started)
        [output, passed]
      end

      # @return [Array(String, Boolean)] what the check printed, and whether it exited 0
      def run_one(check, env, root)
        argv = check.fetch("run").map { |word| word.to_s.sub("{workers}", workers(root).to_s) }
        env = { "RUBOCOP_CACHE_ROOT" => RUBOCOP_CACHE_ROOT }.merge(ENV.slice("RUBOCOP_CACHE_ROOT")).merge(env)
        output, status = RustBuild::GateBuild.capture(argv, env, root)
        [output, status.success?]
      rescue SystemCallError => e
        ["could not start #{argv.first}: #{e.message}", false]
      end

      # @param root [String] the checkout whose Tickets world sets the `spec_workers` cap
      # @return [Integer] half the machine's cores, held to the cap, at least one; the parallel
      #   suite at full width starves the fuzzing run beside it
      def workers(root)
        require "etc"
        require "hecks/hecks/adapters/codebase/spec_workers"
        Hecks::Adapters::Codebase::SpecWorkers.count(root, cores: Etc.nprocessors / 2)
      end

      def list(stages)
        stages.each do |name, stage|
          puts "#{name}: #{stage.fetch("checks").map { |check| check["id"] }.join(", ")}"
        end
        0
      end

      def unknown(stage, only)
        known = stage.fetch("checks").map { |check| check["id"] }
        warn "no such check: #{(only - known).join(", ")} (checks: #{known.join(", ")})"
        2
      end

      def usage(stages, name)
        warn(name ? "no such stage: #{name} (stages: #{stages.keys.join(", ")})" : USAGE)
        2
      end
    end
  end
end
