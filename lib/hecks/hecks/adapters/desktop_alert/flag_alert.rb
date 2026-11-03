# frozen_string_literal: true

require_relative "alert"

module Hecks
  module Adapters
    class DesktopAlert
      # The words of the alert that says main's red flag went up or came down: the flag and the
      # commit as its title, the CI run beneath it, the failed jobs as its body, and the run on
      # GitHub as what a click opens.
      class FlagAlert
        # How many failed job names the body lists.
        JOBS = 4

        # @param held [Hash] the `RedFlag` ask: `outcome`, `flag`, `commit`, `ci_run` and `jobs`
        # @param github [Array(String, String), nil] the remote's GitHub owner and repository
        def initialize(held, github: nil)
          @held = held
          @github = github
        end

        # @return [Alert] the alert to show
        def alert
          Alert.new(title: title, subtitle: subtitle, body: body, link: link)
        end

        private

        def raised? = plain(:outcome) == "raised"

        def title
          state = raised? ? "main is red" : "main is green again"
          "#{state}: #{plain(:flag)}"
        end

        def subtitle
          run = plain(:ci_run)
          "#{plain(:commit).to_s[0, 10]}#{" · CI run #{run}" unless run.to_s.empty?}"
        end

        def body
          return "landing and the push train resume" unless raised?

          jobs = failed_jobs
          return "stop feature work and check in: exe/hecks RedFlag.check_in!" if jobs.empty?

          jobs.first(JOBS).map { |job| "• #{job}" }.join("\n")
        end

        # The failed jobs' names, as the report lists them: comma separated.
        def failed_jobs
          names = plain(:jobs).to_s.split(",")
          names.map(&:strip).reject(&:empty?)
        end

        def link
          owner, name = @github
          run = plain(:ci_run)
          "https://github.com/#{owner}/#{name}/actions/runs/#{run}" if owner && !run.to_s.empty?
        end

        def plain(key)
          value = @held[key]
          value.is_a?(Hash) ? value[:value] : value
        end
      end
    end
  end
end
