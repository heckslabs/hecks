# frozen_string_literal: true

module Hecks
  module QualityControlCli
    class QaOpenPr
      # The rules `patch.open` and `improvement.open` check before anything is opened: the ledger's
      # own `given`s, asked as a dry run, then the day's cap and the bug's commit ancestry.
      module Rules
        private

        def find_citations
          @bug = @angle = nil
          if @options[:bug]
            @bug = ::QualityControl::Bug.find(@options[:bug])
            abort "refused: no such bug #{@options[:bug].inspect}" unless @bug
          end
          return unless @options[:angle]

          @angle = ::QualityControl::Angle.find(@options[:angle])
          abort "refused: no such angle #{@options[:angle].inspect}" unless @angle
        end

        # What a refused `given` says to do next, by the rule's own wording; nothing for a rule it
        # does not know.
        def hint_for(rule)
          case rule
          when "the bug is fixed" then bug_hint
          when "the angle is under investigation" then angle_hint
          when "the branch is one this practice recognises as its own" then branch_hint
          when "the day's cap is not spent" then cap_hint
          else ""
          end
        end

        def bug_hint
          " (#{@bug.id} is #{@bug.status.inspect} — dispatch investigate and fix first " \
            "(hecks run qa/bluebook fix id=#{@bug.id} reference.value=#{@bug.id} commit.value=<sha>))"
        end

        def angle_hint
          " (#{@angle.id} is #{@angle.status.inspect} — dispatch angle.investigate first, so the lead " \
            "reads as picked up before something is built from it)"
        end

        def branch_hint
          " (the branch is #{@branch.inspect}; a PR this practice opens is on a branch it can recognise " \
            "as its own)"
        end

        def cap_hint
          " (QualityControlDials::PR_CAP_PER_DAY is #{dial(:PR_CAP_PER_DAY, 0)} — leave this as an open " \
            "Bug/Angle and open it tomorrow, or raise the dial in qa/settings.yml)"
        end

        # Asks the ledger whether `verb` would take these facts, without recording anything. The
        # number is one no record holds yet, so the dry run reaches the `given`s rather than
        # `AlreadyExists`.
        def refuse_unless_ledger_takes(verb, **facts)
          @runtime.dry_run?(verb, **facts)
        rescue Hecks::Runtime::GivenNotMet => e
          hint = hint_for(e.message.split(" — ", 2).last)
          abort "refused: #{e.message}#{hint} — a dry run of #{verb}, so nothing was opened or recorded"
        end

        def next_number(aggregate)
          query("#{aggregate}.All").map { |row| row[:number][:value] }.max.to_i + 1
        end

        def check_rules
          recorded = recorded_facts
          @bug ? check_patch_rule(recorded) : check_improvement_rule(recorded)
          check_daily_cap
          check_ancestry
        end

        def recorded_facts
          { url: { value: "https://github.com/pull/0" }, title: { value: @options[:title] },
            branch: { value: @branch }, now: { value: Time.now.to_i } }
        end

        def check_patch_rule(recorded)
          commit = @bug.commit.to_h[:value].to_s
          refuse_unless_ledger_takes("QualityControl::Patch.Open",
                                     bug: @bug.id, number: { value: next_number("Patch") },
                                     commit: { value: commit.match?(SHA_PATTERN) ? commit : PLACEHOLDER_COMMIT },
                                     **recorded)
        end

        def check_improvement_rule(recorded)
          refuse_unless_ledger_takes("QualityControl::Improvement.Open",
                                     **(@angle ? { angle: @angle.id } : {}),
                                     number: { value: next_number("Improvement") }, **recorded)
        end

        # The record of the UTC day the clock reads: `DailyQuota.Today` fills the day from the
        # clock.
        def todays_quota = query("DailyQuota.Today").first

        # A day with no record has spent nothing, so only an opened day can refuse.
        def check_daily_cap
          cap = dial(:PR_CAP_PER_DAY, 0)
          quota = todays_quota
          return unless cap.positive? && quota

          refuse_unless_ledger_takes("QualityControl::DailyQuota.Take", today: quota[:today], cap: { value: cap })
        end

        def check_ancestry
          return unless @bug

          commit = @bug.commit.to_h[:value].to_s
          abort "refused: #{@bug.id} carries no commit" unless commit.match?(SHA_PATTERN)

          refusing do
            @git_pr.assert_ancestor!(commit: commit, owner: @bug.id)
            @git_pr.assert_pushed!(branch: @branch, commit: commit, owner: @bug.id)
          end
        end
      end
    end
  end
end
