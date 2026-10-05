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

        name = argv.find { |arg| !arg.include?("=") && !arg.start_with?("--") }
        only = argv.filter_map { |arg| arg.delete_prefix("only=").split(",") if arg.start_with?("only=") }.flatten
        stage = stages[name]
        return usage(stages, name) unless stage

        checks = select(stage.fetch("checks"), only)
        return unknown(stage, only) if checks.nil?

        report(name, checks, run_all(stage, checks, root))
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

      def report(name, checks, results)
        failed = checks.reject { |check| results.fetch(check["id"]).last }
        failed.each do |check|
          output, = results.fetch(check["id"])
          puts "\n[gate #{name}] #{check['title']}\n\n#{output}"
          puts "\n[gate #{name}] BLOCKED: #{check['blocked']}\n"
        end
        if failed.empty?
          puts "[gate #{name}] green: #{checks.map { |check| check['id'] }.join(', ')}"
          return 0
        end

        puts "[gate #{name}] red: #{failed.map { |check| check['id'] }.join(', ')}"
        1
      end

      def list(stages)
        stages.each do |name, stage|
          puts "#{name}: #{stage.fetch('checks').map { |check| check['id'] }.join(', ')}"
        end
        0
      end

      def unknown(stage, only)
        known = stage.fetch("checks").map { |check| check["id"] }
        warn "no such check: #{(only - known).join(', ')} (checks: #{known.join(', ')})"
        2
      end

      def usage(stages, name)
        warn(name ? "no such stage: #{name} (stages: #{stages.keys.join(', ')})" : USAGE)
        2
      end
    end
  end
end
