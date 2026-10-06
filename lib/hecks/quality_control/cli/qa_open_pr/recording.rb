# frozen_string_literal: true

module Hecks
  module QualityControlCli
    class QaOpenPr
      # What `patch.open` and `improvement.open` write to the ledger once the PR exists: the Patch
      # or Improvement record, the day's quota slot and the optional auto-merge.
      module Recording
        private

        # Counts the PR just recorded against the day, opening the day's record on its first.
        def take_daily_slot
          row = todays_quota
          quota = row ? ::QualityControl::DailyQuota.find(row[:today][:value]) : ::QualityControl::DailyQuota.open!
          quota.take!(cap: { value: dial(:PR_CAP_PER_DAY, 0) })
        end

        def record(view)
          number = view[:number]
          sha = view[:headRefOid].to_s
          now = Time.now.to_i
          if @bug
            record_patch(view, number, sha, now)
          else
            record_improvement(view, number, sha, now)
          end
        end

        def record_patch(view, number, sha, now)
          return puts("Patch ##{number} already recorded — not re-recording") if patch_recorded?(number)

          ::QualityControl::Patch.open!(
            bug: @bug.id, number: { value: number }, url: { value: view[:url] },
            branch: { value: view[:headRefName] }, commit: { value: sha }, title: { value: view[:title] },
            now: { value: now }
          )
          take_daily_slot
          puts "recorded Patch ##{number} for #{@bug.id} at #{sha[0, 7]}"
        end

        def patch_recorded?(number)
          query("Patch.All").map { |row| row[:number][:value] }.include?(number)
        end

        def record_improvement(view, number, sha, now)
          existing = ::QualityControl::Improvement.find(number)
          if existing && existing.status != "opened"
            puts "Improvement ##{number} already recorded (#{existing.status}) — not re-recording"
            return
          end

          # A run that stopped between `open!` and `land!` leaves the record `opened`: finish it.
          open_improvement(view, number, now) unless existing
          ::QualityControl::Improvement.find(number).land!(number: { value: number }, commit: { value: sha })
          puts "recorded Improvement ##{number}#{" for #{@angle.id}" if @angle}, landed at #{sha[0, 7]}"
        end

        def open_improvement(view, number, now)
          ::QualityControl::Improvement.open!(
            **(@angle ? { angle: @angle.id } : {}),
            number: { value: number }, url: { value: view[:url] },
            branch: { value: view[:headRefName] }, title: { value: view[:title] },
            now: { value: now }
          )
          take_daily_slot
        end

        def merge_when_green(number)
          begin
            @git_pr.merge_when_green(number)
          rescue Hecks::Adapters::GitPr::CommandFailed => e
            abort "recorded, but #{e.message}"
          end
          puts "auto-merge queued for ##{number} (QualityControlDials::AUTO_MERGE)"
        end
      end
    end
  end
end
