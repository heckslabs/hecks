# frozen_string_literal: true

module Hecks
  module Adapters
    class GhRest
      # The checks of one commit as `statusCheckRollup` lists them: the check runs and the commit
      # statuses together, each in the entry shape GraphQL gave (`name`, `status`, `conclusion`,
      # `detailsUrl` for a check run; `context`, `state`, `targetUrl` for a status).
      class Rollup
        PAGE = 100

        # @param listed [#call] takes a path and a key and answers every item of that list
        def initialize(listed)
          @listed = listed
        end

        # @param sha [String, nil] the commit
        # @return [Array<Hash>] its check runs and statuses; empty without a commit
        def of(sha)
          return [] if sha.to_s.empty?

          check_runs(sha) + statuses(sha)
        end

        private

        def check_runs(sha)
          @listed.call("repos/{owner}/{repo}/commits/#{sha}/check-runs?per_page=#{PAGE}", "check_runs").map do |run|
            { "name" => run["name"], "status" => run["status"].to_s.upcase, "conclusion" => run["conclusion"].to_s.upcase,
              "detailsUrl" => run["details_url"] }
          end
        end

        def statuses(sha)
          @listed.call("repos/{owner}/{repo}/commits/#{sha}/status?per_page=#{PAGE}", "statuses").map do |status|
            { "context" => status["context"], "state" => status["state"].to_s.upcase, "targetUrl" => status["target_url"] }
          end
        end
      end
    end
  end
end
