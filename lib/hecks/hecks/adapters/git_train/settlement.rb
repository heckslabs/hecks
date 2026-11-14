# frozen_string_literal: true

require "open3"
require_relative "reading"
require_relative "branch_guard"
require_relative "named_commit"
require_relative "drift_checks"

module Hecks
  module Adapters
    class GitTrain
      # What a boarding does to a checkout before its carriage carries it: brings the branch up to
      # its remote, and settles an additive shape change into a commit the carriage then pushes.
      #
      # It works on the boarded branch only: to change anything, the checkout must have that branch
      # checked out and clean, and the branch must still name the boarded commit. Its own commit
      # names the ledger paths it wrote, so nothing already staged is swept in. Coders land on the
      # branch while the drift checks run: the settled commit is carried if the branch holds it.
      #
      # A rebase stops only on the ledger file, which is regenerated rather than merged: the
      # upstream copy is taken and the ledger is settled after. Any other conflict aborts the
      # rebase and is reported by path.
      class Settlement
        include Reading

        # The shape ledger a Hecks checkout keeps, beside the bluebooks it records.
        LEDGER = "lib/hecks/hecks/shapes.json"

        # The translation edges an additive settlement writes.
        EDGES = "lib/hecks/hecks/translations"

        # The ledger's own command for an additive change, run from the checkout.
        SETTLE = %w[bundle exec exe/hecks conformance_run.check_shape_ledger! --confirm --additive --wait].freeze

        # The drift checks CI runs after a push lands, run here in check mode before the push: the
        # generated Rust must match a regeneration, and the reserved-name tables and the CI gate
        # rows must match their projections. Each only compares; none rewrites a file.
        DRIFT = [
          %w[bundle exec exe/hecks regeneration_run.regenerate_corpus! --check --wait],
          %w[bundle exec exe/hecks gate_run.gate! stage=ci only=vocabulary_drift --wait],
          %w[bundle exec exe/hecks gate_run.gate! stage=ci only=ci_gates --wait]
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
          @guard = BranchGuard.new(git, checkout, branch)
        end

        # @param boarded [String] the commit the branch named at boarding
        # @return [String] the commit the branch names now, which the carriage then carries
        # @raise [ConsoleCapture::Failure] when the branch moved before it was settled or has lost
        #   the settled commit, the checkout is not on the branch or not clean, the rebase
        #   conflicts outside the ledger, the ledger cannot be settled, or a check finds drift
        def run(boarded)
          fetch
          @expected = boarded
          @guard.unmoved!(boarded)
          rebasing = !ancestor?(tracking, @branch)
          @guard.checked_out! if rebasing || ledger? || hecks_checkout?
          rebase if rebasing
          settle_ledger if ledger?
          check_drift if hecks_checkout?
          held!
          @expected
        end

        private

        def tracking = "#{@remote}/#{@branch}"

        def fetch = read("fetch", "--quiet", @remote, "+refs/heads/#{@branch}:refs/remotes/#{tracking}")

        def ledger? = File.exist?(File.join(@checkout, LEDGER))

        def hecks_checkout? = File.exist?(File.join(@checkout, "exe", "hecks"))

        # Rebases the local branch onto its remote. Stops on the ledger, takes the remote's copy of
        # it, and continues; any other conflicted path aborts the rebase.
        def rebase
          @guard.clean!
          @guard.unmoved!(@expected)
          rebase_onto_remote
        end

        def rebase_onto_remote
          result = git(["rebase", tracking])
          STEPS.times do
            return @expected = @guard.head if result.ok?

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
        # change that is not additive is refused by the settlement, and the refusal stops it.
        def settle_ledger
          ledger_untouched!
          out, err, status = Open3.capture3(*SETTLE, chdir: @checkout)
          refusal = out.lines.find { |line| line.include?('"refusal": "') }
          raise ConsoleCapture::Failure, "the shape ledger was not settled: #{refusal.strip}" if refusal
          raise ConsoleCapture::Failure, "the shape ledger command failed: #{err.strip}" unless status.success?

          commit_ledger
        end

        # The ledger files must hold no edits of anyone's before the settlement writes its own.
        def ledger_untouched!
          return if read("status", "--porcelain", "--", LEDGER, EDGES).empty?

          raise ConsoleCapture::Failure, "#{LEDGER} or #{EDGES} has uncommitted changes; commit or discard them before boarding"
        end

        def check_drift = DriftChecks.new(@checkout, @guard, @drift).run(@expected)

        # Landings above the settled commit are left for the next boarding; a branch that has
        # lost the commit is refused.
        def held!
          return if NamedCommit.new(@git, @checkout, branch: @branch).held?(@expected)

          @guard.unmoved!(@expected)
        end

        def commit_ledger
          changed = read("status", "--porcelain", "--", LEDGER, EDGES)
          return if changed.empty?

          @guard.clean!(except: [LEDGER, EDGES])
          ours_to_commit!

          written = [LEDGER, EDGES].select { |path| File.exist?(File.join(@checkout, path)) }
          read("add", "--", *written)
          read("commit", "-q", "-m", "Settle the shape ledger before boarding", "--", *written)
          @expected = @guard.head
        end

        # A landing that arrived while the ledger was settled must not go out under the
        # settlement's commit, which would carry a commit nobody boarded: what the settlement wrote
        # is dropped, so the next boarding finds the ledger untouched, and the boarding is refused.
        def ours_to_commit!
          return if @guard.head == @expected

          [LEDGER, EDGES].each { |path| git(["checkout", "-q", "HEAD", "--", path]) }
          git(["clean", "-fdq", "--", EDGES])
          @guard.unmoved!(@expected)
        end

        def git(args) = @git.capture(*args, chdir: @checkout)
      end
    end
  end
end
