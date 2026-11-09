# frozen_string_literal: true

module Hecks
  module Adapters
    module PipelineBoard
      # What one AgentRun page shows, read from the run's record and the Landing records of its
      # Work item. Mixed into {PipelineTickets}, which supplies the readers it uses.
      module RunDetail
        FIELDS = %i[run agent works_as repo session status condition detail refusal brief].freeze

        # @param key [String] an AgentRun's key or its session id
        # @return [Hash, nil] the run's brief, agent, status, condition, detail, session, repo,
        #   refusal, Work item and `landed` shas; nil when no run has that key
        def run_detail(key)
          run = run_records.find { |found| [field(found, :run).to_s, field(found, :session).to_s].include?(key) }
          return unless run

          work = work_item_of(run)
          FIELDS.to_h { |name| [name, field(run, name).to_s] }.merge(work: work, landed: landed_commits(work))
        end

        # @param work [String] a Work item's slug
        # @return [Array<String>] the commits the Landing records say the item's branch landed
        def landed_commits(work)
          return [] if work.empty?

          landings = @landed || records_of("Hecks", "Landing")
          mine = landings.select { |land| field(land, :branch).to_s.delete_prefix("qa/") == work }
          mine.map { |land| field(land, :landed).to_s }.reject(&:empty?).uniq
        rescue PipelineBoard::Unavailable
          []
        end
      end
    end
  end
end
