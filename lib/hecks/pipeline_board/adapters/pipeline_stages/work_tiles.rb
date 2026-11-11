# frozen_string_literal: true

require_relative "tile_kit"
require_relative "../rules"

module Hecks
  module Adapters
    module PipelineBoard
      # The tiles that read the work: commits not yet pushed, sessions against the cap and the load
      # against its limit, Work items finished in a day, and the latest release.
      module WorkTiles
        include TileKit

        DAY = 86_400
        # The `Session owner` words of sessions that hold no seat against the cap.
        NOT_SEATED = ["finished leftover", "other repo"].freeze

        # The push nudge comes from the QualityControl world's `push_nudge` setting, passed in.
        def ahead(local, now, limits)
          return unknown_tile("ahead", "Commits not pushed", local) unless readable?(local)

          age = hours_since(local[:oldest_unpushed], now)
          state = Rules.verdict("Commits not pushed", { ahead: local[:ahead], age_hours: age }, limits)
          note = "oldest #{age} h; nudge at #{limits[:commits]} commits or #{limits[:hours]} h"
          tile("ahead", "Commits not pushed", local[:ahead], "commits", state: state, detail: note)
        end

        def working(data)
          return unknown_tile("working", "Dispatched sessions", data[:sessions]) unless data[:sessions].is_a?(Array)

          fill = readable?(data[:fill]) ? data[:fill] : {}
          dispatched, blocked = seats(data[:sessions], fill)
          cap = fill[:cap] || Rules.setting("session_cap")
          state = pressure(dispatched, cap, blocked)
          tile("working", "Dispatched sessions", dispatched, "of #{cap}", state: state, detail: headline(data))
        end

        def headline(data) = Headline.sentence(data[:sessions], data[:fill])

        # The cap (`work_limit`) bounds sessions dispatched for a Work item; the fill's own count of
        # what it started is the seat count when the fill report is readable. Without it, the live
        # sessions holding a Work item count, a finished leftover or a session of another
        # repository not among them.
        #
        # @return [Array(Integer, Integer)] the seats held, and the sessions waiting on the owner
        def seats(sessions, fill)
          live = sessions.select { |session| %w[busy blocked].include?(session[:status]) }
          held = live.count { |session| !session[:work_item].to_s.empty? && !NOT_SEATED.include?(session[:kind]) }
          [fill[:started] || held, live.count { |session| OwnerQueue.waiting?(session) }]
        end

        # Attention when the cap is reached or anyone is waiting on a person.
        def pressure(dispatched, cap, blocked)
          Rules.verdict("Dispatched sessions", { dispatched: dispatched, blocked: blocked }, session_cap: cap)
        end

        # @param finished [Array<Hash>, Hash] the newest `WorkFinished` events, read by name from
        #   the journal, so a flood of other events cannot push them out of the window
        # @param open_work [Array<Hash>, Hash] the open Work items, planned ones among them
        def throughput(finished, open_work, now)
          return unknown_tile("throughput", "Work finished", finished) unless finished.is_a?(Array)

          window = Rules.setting("throughput_window_hours") * 3600
          done = finished.count { |event| now - Time.parse(event[:at]) < window }
          planned = open_work.is_a?(Array) ? open_work.count { |work| work[:status] == "planned" } : nil
          state = Rules.verdict("Work finished", { finished: done, planned: planned })
          tile("throughput", "Work finished", done, "items / 24 h", state: state, detail: finished_note(finished, planned))
        end

        # When the newest Work item finished, and how many still wait in the plan.
        def finished_note(finished, planned)
          last = finished.first && "last #{finished.first[:at].to_s.sub("T", " ").delete_suffix("Z")} UTC"
          waiting = planned && "#{planned} planned"
          [last || "none finished yet", waiting].compact.join("; ")
        end

        def release(release, now)
          return unknown_tile("release", "Latest release", release) unless readable?(release)

          days = release[:published_at] && ((now - Time.parse(release[:published_at])) / DAY).floor
          word = release[:published] ? "published" : "draft"
          tile("release", "Latest release", days, "days ago", detail: "#{release[:tag]} #{word}")
        end

        def readable?(section) = section.is_a?(Hash) && !section.key?(:unknown)

        def hours_since(stamp, now) = stamp ? ((now - Time.parse(stamp)) / 3600.0).round(1) : 0.0

        def load_note(fill) = fill[:load] ? "load #{fill[:load]} of #{fill[:limit]}" : "load unknown"
      end
    end
  end
end
