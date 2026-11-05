# frozen_string_literal: true

require_relative "../rules"

module Hecks
  module Adapters
    module PipelineBoard
      # How the work fans out across sessions: which Work item each session runs, who claimed each,
      # and the flags that say the two disagree. It reads Work items and answers entries; it decides
      # nothing.
      module Fanout
        module_function

        # @param sessions [Array<Hash>] the board's sessions
        # @param work [Array<Hash>] the open Work items
        # @param landed [Array<String>] the branches the Landing records say were merged
        # @param fill [Hash, nil] the Dispatch.Fill preview
        # @return [Array<Hash>] one entry per open Work item: its claim, its sessions and its flags
        def mapping(sessions:, work:, landed:, fill:)
          busy = sessions.select { |s| %w[busy blocked].include?(s[:status]) }
          world = { busy: busy, landed: landed, fill: fill, areas: work.to_h { |w| [w[:slug], w[:area].to_a] } }
          work.map { |item| mapped(item, world) }
        end

        # @return [Array<Hash>] every flag of every Work item, each with its `work_item`, `kind` and
        #   `detail`
        def flags_of(mapped) = mapped.flat_map { |m| m[:flags].map { |flag| flag.merge(work_item: m[:slug]) } }

        def mapped(item, world)
          on = world[:busy].select { |s| s[:work_item] == item[:slug] }
          { slug: item[:slug], status: item[:status], claimed_by: item[:claimed_by], claimed_at: item[:claimed_at],
            sessions: on.map { |s| s[:id] }, flags: flags(item, on, world) }
        end

        def flags(item, on, world)
          found = []
          found << unclaimed(item, on) if on.any? && item[:claimed_by].to_s.empty?
          found << twice(on) if on.size > 1
          found.concat(overlapping(item, on, world))
          found.concat(stale(item, world))
        end

        def unclaimed(item, on)
          { kind: "unclaimed", detail: "#{on.first[:id]} runs on #{item[:slug]}, which has no claimed_by" }
        end

        def twice(on)
          { kind: "duplicate", detail: "#{on.size} sessions run on one work item: #{on.map { |s| s[:id] }.join(", ")}" }
        end

        def overlapping(item, on, world)
          return [] if on.empty?

          clash = world[:busy].select { |s| s[:work_item] != item[:slug] && clashes?(s, item, world) }
          clash.map { |s| { kind: "overlap", detail: "#{s[:id]} (#{s[:work_item]}) works an area that overlaps #{item[:slug]}" } }
        end

        def clashes?(session, item, world) = touches?(world[:areas][session[:work_item]], item[:area].to_a)

        def touches?(mine, theirs)
          mine.to_a.any? { |a| theirs.any? { |b| a.start_with?(b) || b.start_with?(a) } }
        end

        def stale(item, world)
          return [] unless world[:landed].include?(item[:slug]) && Rules.stale_statuses.include?(item[:status])

          [{ kind: "landed", detail: "#{item[:slug]} already landed but is still #{item[:status]}#{restart(item, world)}" }]
        end

        def restart(item, world)
          again = world[:fill].to_h.fetch(:would_start, []).any? { |pick| pick[:slug] == item[:slug] }
          again ? "; Dispatch.Fill would start another session on it" : ""
        end
      end
    end
  end
end
