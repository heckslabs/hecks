# frozen_string_literal: true

require "open3"
require_relative "../cli/qa_main_gate"

module Hecks
  module Adapters
    # The `MainMaintenance` port adapter: the bodies of the three steps a maintenance run asks for. `gate`
    # runs the quick gate on local main through `QaMainGate`; `reconcile` runs `Era.Reconcile`'s read-only
    # plan and writes only when the `maintenance_confirm` dial is true; `push` moves the push train's
    # checkout to main's head and sends it with the full gate and confirmation. Each answers the event its
    # policy waits for, or raises, which the runtime records as the refusal.
    class MainMaintenance
      # Raised when a step refuses; its message is the refusal's reason.
      class Refused < RuntimeError; end

      # The launcher commands the steps run outside the ledger: the reconcile plan and write, and the push
      # train. A spec injects a stub in their place.
      module Commands
        # The push train's own launcher and its detached checkout.
        TRAIN_CHECKOUT = File.expand_path("~/.claude/hecks-train")
        TRAIN_LAUNCHER = File.join(TRAIN_CHECKOUT, "exe/hecks")

        module_function

        # The read-only dry run of `Era.Reconcile`.
        #
        # @return [Array(String, Boolean)] the plan's output and whether it exited 0
        def reconcile_plan(root)
          launch(root, root, "query", "era.reconcile_plan")
        end

        # Writes the reconciliation, confirmed, for one run.
        #
        # @return [Array(String, Boolean)]
        def reconcile_write(root, run)
          launch(root, root, "era.reconcile!", "run.value=#{run}", "confirm.value=true", "--wait")
        end

        # Moves the train checkout to a commit, detached, and sends the branch through the train with the
        # full gate and confirmation.
        #
        # @return [Array(String, Boolean)] the train's output and whether it exited 0
        def train_push(root, sha)
          output, status = Open3.capture2e("git", "-C", TRAIN_CHECKOUT, "checkout", "--detach", sha)
          return [output, false] unless status.success?

          launch(TRAIN_CHECKOUT, root, "SendTrain.board!", "checkout.value=#{root}", "remote.value=origin",
                 "branch.value=main", "full_gate.value=true", "confirm.value=true", "--wait")
        end

        # @return [Array(String, Boolean)]
        def launch(dir, root, *argv)
          output, status = Open3.capture2e(File.join(dir, "exe/hecks"), *argv, chdir: root)
          [output, status.success?]
        end
      end

      # @param aggregate [Object, nil] unused; the runtime passes the held record
      # @param settings [Hash] unused
      # @param root [String, nil] the repository root whose local main the steps act on
      # @param commands [Module] the outside-world commands; a spec injects a stub
      def initialize(aggregate: nil, settings: {}, root: nil, commands: Commands)
        @root = root || Dir.pwd
        @commands = commands
      end

      # Runs the quick gate on main and answers its verdict.
      #
      # @param run [Hash, String] the run key, as a value object or a bare string
      # @param sha [Hash, String] the commit the run is for
      # @return [Hash] `run`, `sha` and `color`
      def gate(run:, sha:, **)
        exit_code = Hecks::QualityControlCli::QaMainGate.call([], root: @root)
        raise Refused, "the quick gate could not run (exit #{exit_code})" if exit_code == 1

        { run: wrap(run), sha: wrap(sha), color: { value: exit_code.zero? ? "green" : "red" } }
      end

      # Plans the reconcile read-only, then writes it only when `maintenance_confirm` is true.
      #
      # @return [Hash] `run`, `sha`, `color` and `verdict` (`reported` or `written`)
      def reconcile(run:, sha:, color:, **)
        output, planned = @commands.reconcile_plan(@root)
        raise Refused, "the reconcile plan refused: #{output.strip}" unless planned

        verdict = write_reconcile?(run) ? "written" : "reported"
        { run: wrap(run), sha: wrap(sha), color: wrap(color), verdict: { value: verdict } }
      end

      # Pushes local main through the train, after the most recent gate verdict on this commit is green and
      # origin is an ancestor of main.
      #
      # @return [Hash] `run`, `sha` and `origin_sha`
      def push(run:, sha:, **)
        commit = value_of(sha)
        raise Refused, "the most recent gate on #{commit[0, 7]} is not green" unless green_recorded?(commit)
        raise Refused, "origin/main is not an ancestor of main" unless origin_ancestor?

        output, passed = @commands.train_push(@root, commit)
        raise Refused, "the train refused the push: #{output.strip}" unless passed

        { run: wrap(run), sha: wrap(commit), origin_sha: { value: git("rev-parse", "origin/main") } }
      end

      private

      def write_reconcile?(run)
        return false unless defined?(::QualityControlDials) && ::QualityControlDials.const_defined?(:MAINTENANCE_CONFIRM)
        return false unless ::QualityControlDials::MAINTENANCE_CONFIRM == true

        output, written = @commands.reconcile_write(@root, value_of(run))
        raise Refused, "the reconcile write refused: #{output.strip}" unless written

        true
      end

      def wrap(value) = { value: value_of(value) }

      def value_of(value) = value.is_a?(Hash) ? value.transform_keys(&:to_s)["value"] : value

      # The most recent MainCheck record for the commit, read from the QA ledger.
      def green_recorded?(commit)
        row = ledger.query("QualityControl::MainCheck.All").find { |check| check[:reference][:value] == commit }
        row&.dig(:verdict, :value) == "green"
      end

      def ledger = @ledger ||= Hecks.boot(File.join(@root, "qa/bluebook"))

      def origin_ancestor?
        _, status = Open3.capture2e("git", "-C", @root, "merge-base", "--is-ancestor", "origin/main", "main")
        status.success?
      end

      def git(*argv)
        output = Open3.capture2e("git", "-C", @root, *argv).first
        output.strip
      end
    end
  end
end
