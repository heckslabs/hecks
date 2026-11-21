# frozen_string_literal: true

module Hecks
  module Adapters
    module PipelineBoard
      # The facts the board's `Glance` asks of the aggregates that own them: the red episodes that
      # stand (`RedEpisode.Standing`), the overloads that stand (`Overload.Standing`) and the open
      # findings an approval is waiting in (`Finding.Open`). Each is the declared query's answer,
      # asked of the live store when the board is told where it is, else of the booted registry.
      # Mixed into {PipelineTickets}, which supplies the store and `field`.
      module StandingFacts
        # The kind of an open finding that is an approval only the owner can give.
        APPROVAL = "approval"

        # @return [Array<Hash>] each standing red episode's `status`, `began_at` (epoch seconds),
        #   `culprit` and `branch`
        def red_episodes
          store.asked("Hecks", "RedEpisode", "Standing").map do |record|
            { status: field(record, :status).to_s, began_at: field(record, :began_at).to_i,
              culprit: field(record, :culprit).to_s, branch: field(record, :branch).to_s }
          end
        end

        # @return [Array<Hash>] each standing overload's `reason`
        def overloads
          store.asked("Hecks", "Overload", "Standing").map { |record| { reason: field(record, :reason).to_s } }
        end

        # @return [Array<Hash>] each open approval finding's `finding` key and `title`
        def approvals
          open = store.asked("Tickets", "Finding", "Open").select { |record| field(record, :kind).to_s == APPROVAL }
          open.map { |record| { finding: field(record, :finding).to_s, title: field(record, :title).to_s } }
        end
      end
    end
  end
end
