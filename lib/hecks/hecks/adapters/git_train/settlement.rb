# frozen_string_literal: true

require "open3"
require_relative "reading"

module Hecks
  module Adapters
    class GitTrain
      # What a boarding does to a checkout before its carriage carries it: brings the branch up to
      # its remote, and, when the checkout keeps a shape ledger, settles an additive shape change
      # into a commit the carriage then pushes.
      #
      # A rebase stops only on the ledger file, which is regenerated rather than merged: the upstream
      # copy is taken and the ledger is settled after. Any other conflict aborts the rebase and is
      # reported by path, so nothing is resolved by guesswork.
      class Settlement
        include Reading

        # The shape ledger a Hecks checkout keeps, beside the bluebooks it records.
        LEDGER = "lib/hecks/hecks/shapes.json"

        # The translation edges an additive settlement writes.
        EDGES = "lib/hecks/hecks/translations"

        # The ledger's own command for an additive change, run from the checkout.
        SETTLE = %w[bundle exec exe/hecks conformance_run.check_shape_ledger --confirm --additive --wait].freeze

        # The drift checks CI runs after a push lands, run here in check mode before the push: the
        # generated Rust must match a regeneration, and the reserved-name tables and the CI gate rows
        # must match their projections. Each only compares; none rewrites a file.
        DRIFT = [
          %w[bundle exec exe/hecks regeneration_run.regenerate_corpus --check --wait],
          %w[bundle exec exe/hecks gate_run.gate stage=ci only=vocabulary_drift --wait],
          %w[bundle exec exe/hecks gate_run.gate stage=ci only=ci_gates --wait]
        ].freeze

        # How many rebase steps are tried before the rebase is given up as stuck.
        STEPS = 50

        # @param git [Git] the adapter every git call goes through
        # @param checkout [String] the repository's top level
        # @param branch [String] the branch being boarded
        # @param remote [String] the remote the branch is pushed to
        # @param drift [Array<Array<String>>] the drift checks a Hecks checkout must pass; the
        #   `DRIFT` list by default, and a spec replaces it
        def initialize(git, checkout, branch:, remote:, drift: DRIFT)
          @git = git
          @checkout = checkout
          @branch = branch
          @remote = remote
          @drift = drift
        end

        # @return [void]
        # @raise [ConsoleCapture::Failure] when the rebase conflicts outside the ledger, or the
        #   ledger cannot be settled
        def run
          fetch
          rebase_onto_remote unless ancestor?(tracking, @branch)
          settle_ledger if ledger?
          check_drift if hecks_checkout?
        end

        private

        def tracking = "#{@remote}/#{@branch}"

        def fetch = read("fetch", "--quiet", @remote, "+refs/heads/#{@branch}:refs/remotes/#{tracking}")

        def ledger? = File.exist?(File.join(@checkout, LEDGER))

        def hecks_checkout? = File.exist?(File.join(@checkout, "exe", "hecks"))

        # Rebases the local branch onto its remote. Stops on the ledger, takes the remote's copy of it,
        # and continues; any other conflicted path aborts the rebase.
        def rebase_onto_remote
          result = git(["rebase", tracking])
          STEPS.times do
            return if result.ok?

            conflicted = read("diff", "--name-only", "--diff-filter=U").lines.map(&:strip)
            return abort_rebase!(conflicted) unless conflicted == [LEDGER]

            read("checkout", "--ours", "--", LEDGER)
            read("add", "--", LEDGER)
            result = git(["-c", "core.editor=true", "rebase", "--continue"])
          end
          raise ConsoleCapture::Failure, "rebase onto #{tracking} did not finish in #{STEPS} steps"
        end

        def abort_rebase!(conflicted)
          git(["rebase", "--abort"])
          raise ConsoleCapture::Failure,
                "#{@branch} does not rebase onto #{tracking}: conflict in #{conflicted.join(", ")}; resolve them by hand"
        end

        # Runs the ledger's own settlement for an additive change, and commits what it wrote. A
        # change that is not additive is refused by the settlement, and the refusal stops the boarding.
        def settle_ledger
          out, err, status = Open3.capture3(*SETTLE, chdir: @checkout)
          refusal = out.lines.find { |line| line.include?('"refusal": "') }
          raise ConsoleCapture::Failure, "the shape ledger was not settled: #{refusal.strip}" if refusal
          raise ConsoleCapture::Failure, "the shape ledger command failed: #{err.strip}" unless status.success?

          commit_ledger
        end

        # Runs each drift check in check mode. The first that finds drift refuses the boarding and
        # names the check and the end of what it printed; nothing is rewritten here.
        def check_drift
          @drift.each do |argv|
            out, status = Open3.capture2e(*argv, chdir: @checkout)
            next if status.success?

            raise ConsoleCapture::Failure, "#{argv.drop(2).join(" ")} found drift; regenerate and commit it first: #{tail(out)}"
          end
        end

        # The last three lines of what a check printed, as one line.
        def tail(out)
          last = out.lines.last(3)
          last.join.strip
        end

        def commit_ledger
          changed = read("status", "--porcelain", "--", LEDGER, EDGES)
          return if changed.empty?

          read("add", "--", LEDGER, EDGES)
          read("commit", "-q", "-m", "Settle the shape ledger before boarding")
        end

        def git(args) = @git.capture(*args, chdir: @checkout)
      end
    end
  end
end
