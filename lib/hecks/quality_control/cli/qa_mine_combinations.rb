# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require_relative "../../../hecks"
require_relative "../../fuzzing/combination_miner"
require_relative "../../fuzzing/domain_generator"
require_relative "../adapters/agent"
require_relative "child"
require_relative "../../cache_dir"
require_relative "../../hecks/adapters/codebase/tree"

module Hecks
  module QualityControlCli
    # The command behind `hecks quality_control target.mine_combinations`: asks an agent to mine the
    # adversarial corpus for new domain combinations, then checks them. It is opt-in and never run
    # by `hecks quality_control sweep.tick` (an agent call costs money and answers differently each
    # run). `--brief` prints the agent's prompt and stops; `--from <dir>` re-checks an earlier run;
    # `--against <domain>` narrows the census; `--agent "cmd"` reads the prompt on stdin;
    # `--confine` limits the default agent to writing the run's candidates directory.
    #
    # The agent defaults to `claude -p` (`QA_MINER_AGENT` overrides); candidates that boot are
    # checked by `hecks quality_control target.check_generated_domains --source`, whose report is
    # this command's report. Exit 0: all clean. 2: a finding (see
    # `.claude/skills/hecks_qa/SKILL.md`). 1: an operational error.
    class QaMineCombinations
      EXIT_OK = 0
      EXIT_ERROR = 1
      RESULT_MARKER = "QA_GENERATED_RESULT "

      # What `--confine` lets the default agent do: read anything, write the candidates directory,
      # run for twenty minutes and spend two dollars.
      CONFINED_TOOLS = %w[Read Glob Grep Write Edit].freeze
      CONFINED_TIMEOUT = 1200
      CONFINED_BUDGET = 2.0

      USAGE = "usage: hecks quality_control mine_combinations [--candidates N] [--rust] [--seeds K] " \
              "[--steps M] " \
              "[--adversarial F] [--repair-rounds R] [--agent CMD] [--confine] [--from <candidates-dir>] " \
              "[--against <domain> …] [--brief]"

      Miner = Hecks::Fuzzing::CombinationMiner

      # Mines and checks the candidates.
      #
      # @param argv [Array<String>] the flags in the usage line
      # @param root [String] the repository root
      # @return [Integer] 0 all clean, 2 a finding, 1 an operational error
      # @raise [SystemExit] on a bad argument, an agent that fails or writes nothing, or no
      #   candidate that boots
      def self.call(argv, root:)
        new(root: root).call(argv)
      end

      # @param root [String] the repository root
      def initialize(root:)
        @root = root
      end

      # @param argv [Array<String>] the flags in the usage line
      # @return [Integer] the exit status
      # @raise [SystemExit] on a bad argument, an agent that fails or writes nothing, or no
      #   candidate that boots
      def call(argv)
        @options = parse(argv.dup)
        return EXIT_OK if @options == :help

        @run_dir = File.join(runs_root, "run-#{Time.now.strftime("%Y%m%d-%H%M%S")}-#{Process.pid}")
        @out_dir = @options[:from] || File.join(@run_dir, "candidates")
        @agent_log = File.join(@run_dir, "agent.log")
        @agent = Hecks::Adapters::Agent.new
        @profile = confinement_profile if @options[:confine]
        @command = @agent.command_for(@options[:agent], @profile)
        corpus = @options[:against].empty? ? Miner.corpus_paths(@root) : @options[:against]
        @brief = Miner.brief(corpus, root: @root, bug_titles: Miner.recent_bug_titles(@root))
        prompt = Miner.prompt(@root, @brief, count: @options[:candidates], out_dir: @out_dir)
        if @options[:brief]
          puts prompt
          return EXIT_OK
        end

        mine(prompt)
      end

      # Each flag that takes a value: the option it sets and how the value is read.
      VALUE_FLAGS = {
        "--candidates" => [:candidates, ->(v) { Integer(v) }], "--seeds" => [:seeds, ->(v) { Integer(v) }],
        "--steps" => [:steps, ->(v) { Integer(v) }], "--adversarial" => [:adversarial, ->(v) { Float(v) }],
        "--repair-rounds" => [:repair_rounds, ->(v) { Integer(v) }], "--agent" => [:agent, :itself.to_proc],
        "--from" => [:from, ->(v) { File.expand_path(v) }]
      }.freeze

      private

      def parse(argv)
        options = { candidates: 3, rust: false, seeds: 5, steps: 25, adversarial: 0.3, repair_rounds: 1,
                    agent: nil, from: nil, brief: false, confine: false, against: [] }
        until argv.empty?
          arg = argv.shift
          if %w[-h --help].include?(arg)
            puts USAGE
            return :help
          end
          parse_flag(options, arg, argv)
        end
        options
      end

      def parse_flag(options, arg, argv)
        case arg
        when *VALUE_FLAGS.keys
          key, reader = VALUE_FLAGS.fetch(arg)
          options[key] = reader.call(argv.shift)
        when "--rust" then options[:rust] = true
        when "--brief" then options[:brief] = true
        when "--confine" then options[:confine] = true
        when "--against" then options[:against] << File.expand_path(argv.shift)
        else abort "#{USAGE}\nunexpected argument: #{arg.inspect}"
        end
      end

      def relative(path) = path.delete_prefix("#{@root}/")

      # Runs are kept under the checkout's `tmp/`; an installed gem, or a root that cannot be
      # written, keeps them under the cache root instead.
      def runs_root
        checkout = Hecks::Adapters::Codebase::Tree.new(root: @root).checkout? && File.writable?(@root)
        checkout ? File.join(@root, "tmp/qa-mined") : Hecks::CacheDir.path("qa-mined")
      end

      # Returns nil when the agent finished, else why it did not.
      def ask_agent(prompt)
        @agent.ask(prompt: prompt, command: @command, chdir: @root, log: @agent_log, profile: @profile)
        nil
      rescue Hecks::Adapters::Agent::Failed => e
        e.message
      end

      # The profile `--confine` runs the agent under: it writes only the candidates directory.
      def confinement_profile
        FileUtils.mkdir_p(@out_dir)
        Hecks::Adapters::AgentProfile.new(confinement: :permissions, tools: CONFINED_TOOLS, writable: [@out_dir],
                                          timeout: CONFINED_TIMEOUT, budget: CONFINED_BUDGET)
      end

      def boot_error(candidate, boot_root)
        dir = Hecks::Fuzzing::DomainGenerator.write(
          { "source" => File.read(candidate[:bluebook]), "aggregates" => [], "policies" => [] },
          File.join(boot_root, candidate[:slug])
        )
        output, = Open3.capture2e(*Child.argv(@root, "qa_generated_domains", "--check", dir, "--seeds", "0"),
                                  chdir: @root)
        line = output.lines.reverse.find { |candidate_line| candidate_line.start_with?(RESULT_MARKER) }
        return "boot check produced no result: #{output.lines.last(5).join.strip}" unless line

        result = JSON.parse(line.delete_prefix(RESULT_MARKER))
        result["status"] == "invalid" ? result["error"] : nil
      end

      def mine(prompt)
        FileUtils.mkdir_p(@out_dir)
        FileUtils.mkdir_p(@run_dir)
        puts "combination miner: #{@brief["corpus"].size} corpus domain(s), " \
             "#{@brief["unmet_pairs"].size} unmet pair(s) — #{relative(@run_dir)}"
        unless @options[:from]
          puts "asking the agent for #{@options[:candidates]} candidate(s) (#{@command.first}; " \
               "log #{relative(@agent_log)})…"
          failure = ask_agent(prompt)
          abort "combination miner: #{failure}" if failure
        end

        candidates = Miner.candidates(@out_dir)
        abort "combination miner: the agent wrote no candidates under #{relative(@out_dir)}" if candidates.empty?

        invalid, repaired = boot_and_repair(candidates)
        report(candidates, invalid, repaired)
        valid = candidates.reject { |candidate| invalid.key?(candidate[:slug]) }
        abort "combination miner: no candidate booted — nothing to check" if valid.empty?

        puts
        check(valid)
      end

      # @return [Array(Hash, Array<String>)] the slug-to-error map of candidates that never booted,
      #   and the slugs a repair round fixed
      def boot_and_repair(candidates)
        boot_root = File.join(@run_dir, "boot")
        failures = candidates.filter_map { |candidate| (error = boot_error(candidate, boot_root)) && [candidate, error] }
        repaired = []
        @options[:repair_rounds].times do |round|
          break if failures.empty? || @options[:from]

          puts "repair round #{round + 1}: #{failures.size} candidate(s) did not boot — back to the agent…"
          failure = ask_agent(Miner.repair_prompt(failures, out_dir: @out_dir))
          abort "combination miner: #{failure}" if failure

          still = failures.filter_map { |candidate, _| (error = boot_error(candidate, boot_root)) && [candidate, error] }
          repaired.concat(failures.map { |candidate, _| candidate[:slug] } - still.map { |candidate, _| candidate[:slug] })
          failures = still
        end
        [failures.to_h { |candidate, error| [candidate[:slug], error] }, repaired]
      end

      def report(candidates, invalid, repaired)
        puts
        candidates.each do |candidate|
          if invalid.key?(candidate[:slug])
            puts "  #{candidate[:slug]}: INVALID — #{invalid[candidate[:slug]]}"
            next
          end

          pairs = begin
            Miner.new_pairs(candidate[:dir], @brief["covered"])
          rescue StandardError, ScriptError => e
            ["(census failed: #{e.class})"]
          end
          puts "  #{candidate[:slug]}: boots#{" (repaired)" if repaired.include?(candidate[:slug])}; " \
               "new pair(s): #{pairs.empty? ? "none" : pairs.join(", ")}"
          first = candidate[:hypothesis].to_s.lines.map(&:strip).find { |line| !line.empty? && !line.start_with?("#") }
          puts "    #{first}" if first
        end
      end

      def check(valid)
        args = ["--start", (Time.now.to_i % 1_000_000).to_s, "--seeds", @options[:seeds].to_s,
                "--steps", @options[:steps].to_s, "--adversarial", @options[:adversarial].to_s]
        args << "--rust" if @options[:rust]
        args.concat(valid.flat_map { |candidate| ["--source", candidate[:bluebook]] })
        _, status = Process.wait2(Process.spawn(*Child.argv(@root, "qa_generated_domains", *args), chdir: @root))
        status.exitstatus || EXIT_ERROR
      end
    end
  end
end
