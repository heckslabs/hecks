# frozen_string_literal: true

module Hecks
  module Adapters
    module PipelineBoard
      # How the work fans out across sessions: which row each session runs, who claimed each row,
      # and the flags that say the two disagree. It reads rows and answers rows; it decides nothing.
      module Fanout
        module_function

        # @param sessions [Array<Hash>] the board's sessions
        # @param work [Array<Hash>] the open Work rows
        # @param landed [Array<String>] the branches the Landing records say were merged
        # @param fill [Hash, nil] the Dispatch.Fill preview
        # @return [Array<Hash>] one row per open Work row: its claim, its sessions and its flags
        def mapping(sessions:, work:, landed:, fill:)
          busy = sessions.select { |s| s[:status] == "busy" }
          world = { busy: busy, landed: landed, fill: fill, areas: work.to_h { |w| [w[:slug], w[:area].to_a] } }
          work.map { |row| mapped(row, world) }
        end

        # @return [Array<Hash>] every flag of every row, each with its `row`, `kind` and `detail`
        def flags_of(mapped) = mapped.flat_map { |m| m[:flags].map { |flag| flag.merge(row: m[:slug]) } }

        def mapped(row, world)
          on = world[:busy].select { |s| s[:row] == row[:slug] }
          { slug: row[:slug], status: row[:status], claimed_by: row[:claimed_by], claimed_at: row[:claimed_at],
            sessions: on.map { |s| s[:id] }, flags: flags(row, on, world) }
        end

        def flags(row, on, world)
          found = []
          found << unclaimed(row, on) if on.any? && row[:claimed_by].to_s.empty?
          found << twice(on) if on.size > 1
          found.concat(overlapping(row, on, world))
          found.concat(stale(row, world))
        end

        def unclaimed(row, on)
          { kind: "unclaimed", detail: "#{on.first[:id]} runs on #{row[:slug]}, which has no claimed_by" }
        end

        def twice(on) = { kind: "duplicate", detail: "#{on.size} sessions run on one row: #{on.map { |s| s[:id] }.join(", ")}" }

        def overlapping(row, on, world)
          return [] if on.empty?

          clash = world[:busy].select { |s| s[:row] != row[:slug] && clashes?(s, row, world) }
          clash.map { |s| { kind: "overlap", detail: "#{s[:id]} (#{s[:row]}) works an area that overlaps #{row[:slug]}" } }
        end

        def clashes?(session, row, world) = touches?(world[:areas][session[:row]], row[:area].to_a)

        def touches?(mine, theirs)
          mine.to_a.any? { |a| theirs.any? { |b| a.start_with?(b) || b.start_with?(a) } }
        end

        def stale(row, world)
          return [] unless world[:landed].include?(row[:slug]) && %w[planned started].include?(row[:status])

          [{ kind: "landed", detail: "#{row[:slug]} already landed but is still #{row[:status]}#{restart(row, world)}" }]
        end

        def restart(row, world)
          again = world[:fill].to_h.fetch(:would_start, []).any? { |pick| pick[:slug] == row[:slug] }
          again ? "; Dispatch.Fill would start another session on it" : ""
        end
      end
    end
  end
end
