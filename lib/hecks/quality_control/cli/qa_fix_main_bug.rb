# frozen_string_literal: true

require_relative "../../../hecks"
# The era subsystem does not load with core (ADR 0033); the QualityControl ledger binds it.
require_relative "../../ports/persistence/plugins/era"
require_relative "qa_main_gate/gate_run"
require_relative "qa_main_gate/worktree"
require_relative "qa_main_gate/shell"
require_relative "qa_main_gate/logging"
require_relative "qa_fix_main_bug/publishing"

module Hecks
  module QualityControlCli
    # The command behind `hecks quality_control bug.fix_and_land --bug BUG#n`: takes one
    # self-contained red-main bug through a fix on a fresh branch off main, the quick gate on that
    # exact commit, a landing on local main, and a push through the push train. A bug triaged
    # bigger, or one whose fixer changes nothing or leaves a check red, stops before anything lands
    # and stays open for the owner. Nothing is landed unless the gate is green on the commit, and
    # nothing is pushed unless the gate is green on main's head.
    #
    # Exit 0 when the fix is landed (pushed, or the push's refusal is printed), 1 when refused
    # before any fix, 2 when the fix stays red.
    class QaFixMainBug
      include Publishing

      EXIT_OK = 0
      EXIT_REFUSED = 1
      EXIT_STUCK = 2

      # The file a `rubocop` offense line starts with, as `file.rb:12:3: C: ...` prints it.
      RUBOCOP_OFFENSE = /^(\S+\.rb):\d+:\d+:/

      # The trailer every commit the practice writes carries.
      TRAILER = "Co-Authored-By: Claude Haiku 5.5 <noreply@anthropic.com>"

      USAGE = "usage: hecks quality_control bug.fix_and_land --bug BUG#n"

      # The outcome of one bug's attempt.
      #
      # @!attribute [r] code
      #   @return [Integer] the exit status this attempt earns
      # @!attribute [r] message
      #   @return [String] one line for the report
      Outcome = Struct.new(:code, :message)

      # A fix attempt that did not produce a green commit.
      Stuck = Struct.new(:reason)

      # Runs the command.
      #
      # @param argv [Array<String>] `--bug BUG#n`
      # @param root [String] the repository root
      # @param env [Hash{String => String}] `QA_SWEEP_DOMAIN_DIR` picks another ledger
      # @param gate [#run] the quick gate's runner; a spec injects one
      # @param shell [Module] the fixer, landing and push commands; a spec injects one
      # @return [Integer] the exit status
      def self.call(argv, root:, env: ENV, gate: QaMainGate::GateRun, shell: QaMainGate::Shell)
        reference = parse(argv)
        return EXIT_REFUSED unless reference

        runtime = Hecks.boot(env.fetch("QA_SWEEP_DOMAIN_DIR", File.join(root, "qa/bluebook")))
        outcome = new(runtime: runtime, root: root, gate: gate, shell: shell).fix(reference)
        puts outcome.message
        outcome.code
      end

      # @return [String, nil] the reference, or nil after printing the usage for bad arguments
      def self.parse(argv)
        index = argv.index("--bug")
        return argv[index + 1] if index && argv[index + 1]

        warn USAGE
        nil
      end

      # @param runtime [Object] the booted QualityControl ledger
      # @param root [String] the repository root
      # @param gate [#run] the quick gate's runner
      # @param shell [Module] the fixer, landing and push commands
      def initialize(runtime:, root:, gate:, shell:)
        @runtime = runtime
        @root = root
        @gate = gate
        @shell = shell
      end

      # @param reference [String] the bug's reference, such as `BUG#12`
      # @return [Outcome] what happened, once, in one line
      def fix(reference)
        row = bug_row(reference)
        refusal = refusal_for(reference, row)
        return Outcome.new(EXIT_REFUSED, "refused: #{refusal}") if refusal

        attempt(row)
      rescue QaMainGate::Worktree::Failed => e
        Outcome.new(EXIT_STUCK, "stopped: #{e.message}")
      end

      private

      def attempt(row)
        branch = branch_for(row[:reference][:value])
        return Outcome.new(EXIT_REFUSED, "refused: branch #{branch} already exists") if branch_exists?(branch)

        investigate(row)
        outcome = QaMainGate::Worktree.with(root: @root, ref: "main", branch: branch) { |dir| fix_in(dir, row) }
        return stuck(row, outcome.reason) if outcome.is_a?(Stuck)

        land_and_push(row, branch, outcome)
      end

      def bug_row(reference)
        @runtime.query("QualityControl::Bug.All").find { |row| row[:reference][:value] == reference }
      end

      # @return [String, nil] why the bug is not fixed by this command, nil when it may be
      def refusal_for(reference, row)
        return "no such bug #{reference}" unless row
        return "#{reference} is triaged #{row[:disposition][:value]}; a bigger bug is left for the owner" unless
          row[:disposition][:value] == "self_contained"
        return "#{reference} is #{row[:status]}; nothing to fix" unless %w[logged investigating].include?(row[:status])

        "no mechanical fixer for #{check_id(row)}" unless QaMainGate::Logging::SELF_CONTAINED.include?(check_id(row))
      end

      # @return [String] the gate check the bug is about, such as `rubocop`
      def check_id(row)
        (row[:name] && row[:name][:value]).to_s.delete_prefix("main-red-").tr("-", "_")
      end

      # @return [Array<String>] the files the failing check named, from its own output
      def files_of(row)
        row[:demonstration][:value].scan(RUBOCOP_OFFENSE).flatten.uniq
      end

      def branch_for(reference)
        "qa/red-main-#{reference.downcase.tr("#", "-")}"
      end

      def branch_exists?(branch)
        QaMainGate::Worktree.git?(@root, "rev-parse", "--verify", "--quiet", "refs/heads/#{branch}")
      end

      # The fixer runs, then the gate on the exact commit it makes. Returns the commit, or what kept
      # it red.
      def fix_in(dir, row)
        @shell.rubocop(dir, files_of(row))
        return Stuck.new("the fixer changed nothing") unless changed?(dir)

        sha = commit(dir, row)
        reds = @gate.run(dir).reject(&:passed)
        return sha if reds.empty?

        Stuck.new("the quick gate is still red on the fix: #{reds.map(&:id).join(", ")}")
      end

      def changed?(dir)
        !QaMainGate::Worktree.git!(dir, "status", "--porcelain").empty?
      end

      def commit(dir, row)
        QaMainGate::Worktree.git!(dir, "add", "-A")
        title = "Fix the quick gate on main: #{check_id(row)} (#{row[:reference][:value]})"
        QaMainGate::Worktree.git!(dir, "commit", "-m", title, "-m", TRAILER)
        QaMainGate::Worktree.git!(dir, "rev-parse", "HEAD")
      end
    end
  end
end
