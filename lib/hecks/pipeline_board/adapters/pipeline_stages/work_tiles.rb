# frozen_string_literal: true

require_relative "tile_kit"

module Hecks
  module Adapters
    module PipelineBoard
      # The tiles that read the work: commits not yet pushed, sessions against the cap and the load
      # against its limit, rows finished in a day, and the latest release.
      module WorkTiles
        include TileKit

        NUDGE_COMMITS = 15
        NUDGE_HOURS = 6
        DEFAULT_CAP = 8
        DAY = 86_400

        def ahead(local, now)
          return unknown_tile("ahead", "Commits not pushed", local) unless readable?(local)

          age = hours_since(local[:oldest_unpushed], now)
          over = local[:ahead] >= NUDGE_COMMITS || age >= NUDGE_HOURS
          note = "oldest #{age} h; nudge at #{NUDGE_COMMITS} commits or #{NUDGE_HOURS} h"
          tile("ahead", "Commits not pushed", local[:ahead], "commits", state: over ? "attention" : "ok", detail: note)
        end

        def working(data)
          return unknown_tile("working", "Sessions busy", data[:sessions]) unless data[:sessions].is_a?(Array)

          busy, blocked = counted(data[:sessions])
          fill = readable?(data[:fill]) ? data[:fill] : {}
          cap = fill[:cap] || DEFAULT_CAP
          note = "#{blocked} blocked on you; #{load_note(fill)}"
          tile("working", "Sessions busy", busy, "of #{cap}", state: pressure(busy, cap, blocked), detail: note)
        end

        # @return [Array(Integer, Integer)] the sessions holding a seat (busy or blocked), and the
        #   blocked ones among them
        def counted(sessions)
          [sessions.count { |session| %w[busy blocked].include?(session[:status]) },
           sessions.count { |session| session[:status] == "blocked" }]
        end

        # Attention when the cap is reached or anyone is waiting on a person.
        def pressure(busy, cap, blocked) = busy >= cap || blocked.positive? ? "attention" : "ok"

        # @param finished [Array<Hash>, Hash] the newest `WorkFinished` events, read by name from
        #   the journal, so a flood of other events cannot push them out of the window
        def throughput(finished, now)
          return unknown_tile("throughput", "Work finished", finished) unless finished.is_a?(Array)

          done = finished.count { |event| now - Time.parse(event[:at]) < DAY }
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
