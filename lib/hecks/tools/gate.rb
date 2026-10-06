# frozen_string_literal: true

require "open3"
require "yaml"
require_relative "../tools"

module Hecks
  module Tools
    # Runs a stage's checks, which `lib/hecks/gate/stages.yml` holds as data, all at once and
    # reports every one, so a red check does not hide the others.
    #
    #   hecks gate pre_push                # every check of the stage
    #   hecks gate pre_push only=rubocop   # the named checks
    #   hecks gate --list                  # the stages and their checks
    #
    # A green stage prints which checks passed; a red one prints each failing check's whole output
    # and what its failure means, and answers status 1.
    module Gate
      STAGES_FILE = File.expand_path("../gate/stages.yml", __dir__)
      USAGE = "usage: hecks gate <stage> [only=a,b] | hecks gate --list"

      module_function

      # @param argv [Array<String>] a stage name and optionally `only=a,b`, or `--list`
      # @param root [String] the checkout the checks run in
      # @return [Integer] 0 when every check passed, 1 when one failed, 2 on bad usage
      def main(argv, root: Tools::ROOT, **)
        stages = YAML.load_file(STAGES_FILE, aliases: true)
        return list(stages) if argv == ["--list"]

        name, only = parse(argv)
        stage = stages[name]
        return usage(stages, name) unless stage

        checks = select(stage.fetch("checks"), only)
        return unknown(stage, only) if checks.nil?

        report(name, checks, run_all(stage, checks, root))
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
      # @return [Hash{String => Array}] each check's id, and its output and whether it passed
      def run_all(stage, checks, root)
        env = stage.fetch("env", {}).reject { |key, _| ENV.key?(key) }
        threads = checks.map do |check|
          Thread.new { [check["id"], run_one(check, env, root)] }
        end
        threads.to_h(&:value)
      end

      # @return [Array(String, Boolean)] what the check printed, and whether it exited 0
      def run_one(check, env, root)
        argv = check.fetch("run").map { |word| word.to_s.sub("{workers}", workers.to_s) }
        output, status = Open3.capture2e(env, *argv, chdir: root)
        [output, status.success?]
      rescue SystemCallError => e
        ["could not start #{argv.first}: #{e.message}", false]
      end

      # @return [Integer] half the machine's cores, at least one; the parallel suite at full width
      #   starves the fuzzing run beside it
      def workers
        require "etc"
        [Etc.nprocessors / 2, 1].max
      end

      # @param name [String] the stage name
      # @param checks [Array<Hash>] the checks that ran
      # @param results [Hash{String => Array}] each check's output and whether it passed
      # @return [Integer] 0 when every check passed, 1 otherwise
      def report(name, checks, results)
        failed = checks.reject { |check| results.fetch(check["id"]).last }
        failed.each { |check| print_failure(name, check, results.fetch(check["id"]).first) }
        return summary(name, "red", failed, 1) unless failed.empty?

        summary(name, "green", checks, 0)
      end

      # @return [Integer] the given status, after printing the stage's verdict and its check ids
      def summary(name, verdict, checks, status)
        puts "[gate #{name}] #{verdict}: #{checks.map { |check| check["id"] }.join(", ")}"
        status
      end

      # @return [void] prints a failing check's output and what its failure means
      def print_failure(name, check, output)
        puts "\n[gate #{name}] #{check["title"]}\n\n#{output}"
        puts "\n[gate #{name}] BLOCKED: #{check["blocked"]}\n"
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
