# frozen_string_literal: true

module Hecks
  module QualityControlCli
    class QaPrCheck
      # What `clearance.check_pull_requests` does with one tracked PR: retire it when GitHub says it
      # is settled, skip it while checks run, otherwise ask the ledger for a verdict on its head.
      module Checking
        # The `gh` state of a settled PR to the ledger command that retires it and what to say.
        RETIREMENTS = { "MERGED" => ["Merge", "merged"], "CLOSED" => ["Close", "closed without merging"] }.freeze

        # One tracked PR as the checks see it: its worklist aggregate, number and display label, the
        # bug or angle it cites, and the live head sha.
        Pull = Struct.new(:aggregate, :number, :label, :citation, :sha) do
          # @return [String] the prefix every line about this PR starts with
          def tag
            "#{label}, #{citation}, #{sha[0, 7]}"
          end

          # @param summary [String] what the CI port said about the red head
          # @return [Hash] the newly-red record the report prints
          def finding(summary)
            { aggregate: aggregate, pr: number, citation: citation, commit: sha, refusal: summary }
          end
        end

        private

        # Checks one tracked PR, appending to `@newly_red` or `@operational_errors`. The live head
        # sha is read from gh each run, since a push mints a new commit to clear.
        def check_one_pr(row, aggregate:, citation_field:, citation_label:)
          number = field(row, :number, :value)
          label = "#{aggregate} PR ##{number} (#{field(row, :branch, :value)})"
          view = reading_gh(label) { @git_pr.pull_request(number) }
          return unless view
          return if retire_if_settled?(view, number, label, aggregate)

          sha = view[:headRefOid].to_s
          return reject_sha(label, sha) unless sha.match?(SHA_PATTERN)

          citation = citation_for(row, citation_field, citation_label)
          check_clearance(Pull.new(aggregate, number, label, citation, sha))
        end

        def reject_sha(label, sha)
          @operational_errors << "#{label}: head commit #{sha.inspect} does not look like a sha — skipping"
        end

        def citation_for(row, citation_field, citation_label)
          cited = field(row, citation_field)
          cited ? "#{citation_label} #{cited}" : "no #{citation_label} cited"
        end

        def check_clearance(pull)
          existing = clearance_for_commit(pull.sha)
          return puts("#{pull.tag}: already cleared (#{existing[:status]}) — settled once, not re-checked") if existing
          return unless checks_settled?(pull)

          ask_the_ledger(pull)
        end

        def clearance_for_commit(sha)
          query("Clearance.All").find { |row| field(row, :commit, :value) == sha }
        end

        # Retires a Patch/Improvement whose PR GitHub reports merged or closed; nothing else tells
        # the ledger. Returns true if it retired one.
        def retire_if_settled?(view, number, label, aggregate)
          verb, outcome = RETIREMENTS[view[:state]]
          return false unless verb

          @runtime.dispatch_flat("QualityControl::#{aggregate}.#{verb}", { id: number })
          puts "#{label}: #{outcome} — retired from the worklist"
          true
        end

        # Runs a read against `gh`; a failure is appended to `@operational_errors` and answers nil.
        def reading_gh(label)
          yield
        rescue Hecks::Adapters::GitPr::CommandFailed => e
          @operational_errors << "#{label}: #{e.message}"
          nil
        end

        # True when every check has finished, so a verdict is worth asking for. Pending stays out
        # here because the CI port cannot express "ask again later".
        def checks_settled?(pull)
          checks = reading_gh(pull.label) { @git_pr.checks(pull.number) }
          return false unless checks

          reason = unsettled_reason(checks)
          puts "#{pull.tag}: #{reason} — skipping this run" if reason
          reason.nil?
        end

        def unsettled_reason(checks)
          return "gh reports no checks at all yet" if checks.empty?

          "checks still running" if checks.any? { |c| c[:bucket] == "pending" }
        end

        # Starts a Clearance and asks the CI port for a verdict. ClearOnPass/RefuseOnFail settle
        # the record synchronously, so `find` sees it straight away; a red one is appended to
        # `@newly_red`.
        def ask_the_ledger(pull)
          ::QualityControl::Clearance.start!(commit: { value: pull.sha })
          @runtime.dispatch_flat("QualityControl::Clearance.CI.Run", { commit: pull.sha })
          cleared = ::QualityControl::Clearance.find(pull.sha)
          summary = cleared.summary.to_h[:value]
          return puts("#{pull.tag}: CLEARED — #{summary}") if cleared.status == "green"

          puts "#{pull.tag}: RED — #{summary}"
          @newly_red << pull.finding(summary)
        end
      end
    end
  end
end
