# frozen_string_literal: true

module Hecks
  module Adapters
    class GithubListening
      # The few facts of one GitHub payload the `GithubEvent.Record` command takes, read from the
      # documented shapes of `check_run`, `check_suite`, `pull_request` and `workflow_run`. A fact
      # the payload does not carry is left out; nothing else of the payload is kept.
      module Facts
        module_function

        # @param event [String] the `X-GitHub-Event` header
        # @param payload [Hash] the parsed body
        # @return [Hash{Symbol => Object}] `action`, `pr`, `commit`, `branch`, `conclusion`,
        #   `check` and `ci_run`, each present only when the payload has it
        def of(event, payload)
          subject = payload[event].is_a?(Hash) ? payload[event] : {}
          { action: payload["action"], pr: pr(event, subject), commit: commit(subject),
            branch: branch(subject), conclusion: conclusion(event, subject), check: subject["name"],
            ci_run: event == "workflow_run" ? subject["id"]&.to_s : nil }.compact
        end

        # A pull request's own number, or the first pull request a check or run belongs to.
        def pr(event, subject)
          return subject["number"] if event == "pull_request"

          Array(subject["pull_requests"]).first&.fetch("number", nil)
        end

        def commit(subject) = subject["head_sha"] || subject.dig("head", "sha")

        def branch(subject)
          subject["head_branch"] || subject.dig("head", "ref") || subject.dig("check_suite", "head_branch")
        end

        # A pull request is `merged` or its state; a check or run is its conclusion, or its status
        # while it has none.
        def conclusion(event, subject)
          return subject["merged"] ? "merged" : subject["state"] if event == "pull_request"

          done = subject["conclusion"]
          done.nil? ? subject["status"] : done
        end
      end
    end
  end
end
