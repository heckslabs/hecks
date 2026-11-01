# frozen_string_literal: true

require "json"
require "open3"
require "fileutils"
require_relative "../cli/qa_main_gate"
require_relative "qa_era_mint"
require_relative "qa_auto_mint"

module Hecks
  module Adapters
    # The `MainMaintenance` port adapter: the bodies of the steps a maintenance run asks for. `gate`
    # runs the quick gate on local main through `QaMainGate`; `reconcile` runs `Era.Reconcile`'s
    # read-only
    # plan and writes only when the `maintenance_confirm` dial is true; `push` moves the push
    # train's
    # checkout to main's head and sends it with the full gate and confirmation. Each answers the
    # event its
    # policy waits for, or raises, which the runtime records as the refusal.
    class MainMaintenance
      # Raised when a step refuses; its message is the refusal's reason.
      class Refused < RuntimeError; end

      # Where a stranded landing is recorded. The owner resolves it by removing the file.
      STRANDED_DIR = ENV.fetch("HECKS_MINT_STATE", File.expand_path("~/.claude/hecks-dev/mint")).freeze

      # The launcher commands the steps run outside the ledger: the reconcile plan and write, the
      # mint, the
      # landing, and the push train. A spec injects a stub in their place.
      module Commands
        # The push train's own launcher and its detached checkout.
        TRAIN_CHECKOUT = File.expand_path("~/.claude/hecks-train")
        TRAIN_LAUNCHER = File.join(TRAIN_CHECKOUT, "exe/hecks")

        module_function

        # The mint of one era of a domain, through the era check with the mint command's request.
        #
        # @return [Array(String, Boolean)] the minted era's label or the refusal, and whether it
        #   minted
        def mint_era(root, domain:, era:, request:, ledger: nil)
          QaEraMint.call(root, domain: domain, era: era, request: request, ledger: ledger)
        end

        # The auto-mint rule's facts of one ledger: its live watermark, the edge and the shape diff.
        #
        # @return [Hash] see `QaAutoMint.facts`
        def auto_mint_facts(ledger)
          QaAutoMint.facts(ledger)
        end

        # The journal rows a run's own record wrote above a watermark.
        #
        # @return [Integer]
        def own_rows_after(ledger, run, watermark)
          QaAutoMint.own_rows_after(ledger, run, watermark)
        end

        # Lands a minted era's branch on main through the landing command, with confirmation.
        #
        # @return [Array(String, Boolean)]
        def land(root, branch)
          launch(root, root, "landing.land!", "checkout.value=#{root}", "branch.value=#{branch}", "--confirm",
                 "--wait")
        end

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

        # Moves the train checkout to a commit, detached, and sends the branch through the train
        # with the
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

      # Mints one era of a domain. Refuses while a stranded landing is unresolved, and unless the
      # rehearsal
      # said would_mint. A mint runs when the owner confirmed it or the auto-mint rule holds
      # (`authorize!`); a mint the rule does not cover is refused as "needs owner approval".
      #
      # @param request [Hash] the `MintRequested` attributes: `run`, `domain`, `era`, `sha`,
      #   `branch`,
      #   `watermark`, `rehearsal_verdict`, `refusal_total`, `ledger_dir` and `confirm`
      # @return [Hash] `run`, `domain`, `era`, `sha`, `branch` and `label`
      def mint(**request)
        refuse_while_stranded!
        refuse_unrehearsed!(value_of(request[:rehearsal_verdict]))
        label = run_mint!(request, authorize!(request))
        %i[run domain era sha branch].to_h { |key| [key, wrap(request[key])] }.merge(label: wrap(label))
      end

      # Answers a held mint's approval request: the mint waits for the owner, and nothing follows
      # it.
      #
      # @return [Hash] `domain`, `era` and `reason`
      def approval(domain:, era:, reason:, **)
        { domain: wrap(domain), era: wrap(era), reason: wrap(reason) }
      end

      # Lands the branch that carries a minted era onto main in the same step. A landing that fails
      # leaves
      # the ledger ahead of main, so the run is stranded: the marker is written, and every later
      # mint
      # refuses until the owner removes it.
      #
      # @return [Hash] `run`, `era`, `sha` and `branch`, which `MintStranded` takes on refusal
      def land(run:, era:, sha:, branch:, **)
        output, landed = @commands.land(@root, value_of(branch))
        strand!(run, era, sha, output) unless landed
        { run: wrap(run), era: wrap(era), sha: wrap(sha), branch: wrap(branch) }
      end

      # Pushes local main through the train, after the most recent gate verdict on this commit is
      # green and
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

      def refuse_unrehearsed!(verdict)
        raise Refused, "the rehearsal said #{verdict}, not would_mint" unless verdict == "would_mint"
      end

      # Lets a mint through when the owner confirmed it, or when the auto-mint rule holds on the
      # ledger's
      # facts at the live watermark, and answers that watermark. A stale watermark is a refusal; any
      # other unmet rule holds the mint.
      def authorize!(request)
        ledger = ledger_of(request)
        facts = @commands.auto_mint_facts(ledger)
        stale = QaAutoMint.stale_for(@commands, ledger, value_of(request[:run]), value_of(request[:watermark]), facts[:watermark])
        raise Refused, stale if stale

        held = QaAutoMint.hold_reason(facts, value_of(request[:confirm]), value_of(request[:refusal_total]))
        raise Refused, "needs owner approval: #{held}" if held

        facts[:watermark]
      end

      def ledger_of(request) = QaAutoMint.ledger_for(@root, value_of(request[:ledger_dir]))

      # Runs the era check's mint through the mint command, and answers the label it minted. The
      # mint is
      # confirmed here, because `authorize!` has let it through.
      def run_mint!(request, watermark)
        output, minted = @commands.mint_era(@root, domain:  value_of(request[:domain]),
                                                   era:     value_of(request[:era]),
                                                   ledger:  ledger_of(request),
                                                   request: {
                                                     confirm:   true,
                                                     verdict:   value_of(request[:rehearsal_verdict]),
                                                     watermark: watermark
                                                   })
        raise Refused, output.strip unless minted

        output.strip
      end

      def stranded_path = File.join(STRANDED_DIR, "stranded.json")

      def refuse_while_stranded!
        return unless File.exist?(stranded_path)

        raise Refused, "mints are refused until the stranded landing is resolved: #{File.read(stranded_path).strip}"
      end

      def strand!(run, era, sha, output)
        FileUtils.mkdir_p(STRANDED_DIR)
        record = { run: value_of(run), era: value_of(era), sha: value_of(sha), reason: output.strip }
        File.write(stranded_path, JSON.generate(record))
        raise Refused, "the landing failed after the mint of era #{value_of(era)}: #{output.strip}"
      end

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
