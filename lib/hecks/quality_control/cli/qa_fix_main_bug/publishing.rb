# frozen_string_literal: true

module Hecks
  module QualityControlCli
    class QaFixMainBug
      # What happens after a fix is committed: the ledger records the investigation and the fix, the branch
      # lands on local main, the ledger records the verification, and main is pushed through the push train.
      # The push runs only after the quick gate is green on main's head, and origin's main is fetched right
      # before it.
      module Publishing
        private

        # Records where the bug lives and why, before any fix is attempted. Only a logged bug is
        # investigated; a bug already investigated keeps its first note.
        def investigate(row)
          return unless row[:status] == "logged"

          files = files_of(row)
          ::QualityControl::Bug.find(row[:reference][:value]).investigate!(
            site:  { value: files.empty? ? "the quick gate's output" : files.join(", ") },
            cause: { value: "the quick gate's #{check_id(row)} check is red on main" }
          )
        end

        def stuck(row, reason)
          Outcome.new(EXIT_STUCK,
                      "stays a bug: #{reason} (#{row[:reference][:value]}); left investigating for the owner")
        end

        def land_and_push(row, branch, sha)
          reference = row[:reference][:value]
          bug = ::QualityControl::Bug.find(reference)
          bug.fix!(reference: { value: reference }, commit: { value: sha })
          output, landed = @shell.land(@root, branch)
          return Outcome.new(EXIT_STUCK, "stopped: landing #{branch} was refused: #{output.strip}") unless landed

          delete_branch(branch)
          bug.verify!(evidence: { value: "quick gate green on #{sha[0, 7]} and landed on local main from #{branch}" })
          push_main(reference)
        end

        def delete_branch(branch)
          QaMainGate::Worktree.try(@root, "branch", "-d", branch)
        end

        # @return [Array<QaMainGate::GateRun::Result>] the checks that are red on a commit of main
        def red_at(head)
          QaMainGate::Worktree.with(root: @root, ref: head) { |dir| @gate.run(dir) }.reject(&:passed)
        end

        def push_main(reference)
          head = QaMainGate::Worktree.git!(@root, "rev-parse", "main")
          reds = red_at(head)
          return unpushed("main at #{head[0, 7]} is red: #{reds.map(&:id).join(", ")}") if reds.any?

          behind = behind_origin
          return unpushed(behind) if behind

          output, pushed = @shell.push(@root)
          return Outcome.new(EXIT_OK, "landed and pushed #{reference} (main at #{head[0, 7]})") if pushed

          unpushed("the push train refused main: #{output.strip}")
        end

        # Fetches origin's main right before the push. @return [String, nil] why main cannot be pushed as it is
        def behind_origin
          QaMainGate::Worktree.git!(@root, "fetch", "origin", "main")
          return nil if QaMainGate::Worktree.git?(@root, "merge-base", "--is-ancestor", "origin/main", "main")

          "origin/main has commits local main does not have; pull main first (nothing was pushed)"
        end

        def unpushed(reason)
          Outcome.new(EXIT_STUCK, "landed, not pushed: #{reason}")
        end
      end
    end
  end
end
