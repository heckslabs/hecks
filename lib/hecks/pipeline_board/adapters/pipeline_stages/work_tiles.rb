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

          alive, dispatched, blocked = counted(data[:sessions])
          fill = readable?(data[:fill]) ? data[:fill] : {}
          cap = fill[:cap] || Rules.setting("session_cap")
          note = "#{alive} sessions alive, #{blocked} blocked on you; #{load_note(fill)}"
          tile("working", "Dispatched sessions", dispatched, "of #{cap}", state: pressure(dispatched, cap, blocked), detail: note)
        end

        # The cap (`work_limit`) bounds sessions dispatched for a Work item; a session started by
        # hand holds no Work item and no seat.
        #
        # @return [Array(Integer, Integer, Integer)] the live sessions (busy or blocked), those
        #   among them dispatched for a Work item, and the blocked ones
        def counted(sessions)
          alive = sessions.select { |session| %w[busy blocked].include?(session[:status]) }
          dispatched = alive.count { |session| !session[:work_item].to_s.empty? }
          [alive.size, dispatched, alive.count { |session| session[:status] == "blocked" }]
        end

        # Attention when the cap is reached or anyone is waiting on a person.
        def pressure(dispatched, cap, blocked)
          Rules.verdict("Dispatched sessions", { dispatched: dispatched, blocked: blocked }, session_cap: cap)
        end

        # @param finished [Array<Hash>, Hash] the newest `WorkFinished` events, read by name from
        #   the journal, so a flood of other events cannot push them out of the window
        def throughput(finished, now)
          return unknown_tile("throughput", "Work finished", finished) unless finished.is_a?(Array)

          window = Rules.setting("throughput_window_hours") * 3600
          done = finished.count { |event| now - Time.parse(event[:at]) < window }
          tile("throughput", "Work finished", done, "items / 24 h", detail: "Work.WorkFinished events in the Tickets journal")
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
