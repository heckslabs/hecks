# frozen_string_literal: true

require_relative "../../../../../quality_control/adapters/qa_auto_mint"

module Hecks
  module Adapters
    class JournalStore
      module Readings
        module MintPlan
          # The command line that runs the mint the plan found would go ahead: the Hecks domain's
          # `Era.mint_held!`, or the ledger's `Maintenance.mint_era!`. Whatever the run supplies
          # is a `<placeholder>`; the rest is read from the store. `--confirm` is added when the
          # auto-mint rule (`QaAutoMint.held_reason`) holds the mint for the owner.
          class CommandLine
            # @param held [HeldDomain] the loaded domain
            # @param verdict [LineageManager::MintDecision::Verdict] the decision
            # @param latest [Hash] the latest held era
            # @param watermark [Integer] the live watermark
            def initialize(held, verdict, latest, watermark)
              @held = held
              @verdict = verdict
              @latest = latest
              @watermark = watermark
            end

            # @return [String] the command line
            def to_s
              return held_line if @held.domain_name == "Hecks"

              [*ledger_line, ("--confirm" if confirm?)].compact.join(" ")
            end

            private

            def held_line
              "exe/hecks Era.mint_held! run.value=<run-id> rehearsal_verdict.value=#{@verdict.verdict} " \
                "watermark.value=#{@watermark} --confirm"
            end

            def ledger_line
              ["exe/hecks Maintenance.mint_era! run.value=<run-id> domain=#{@held.domain_name} era=#{@latest[:ordinal] + 1}",
               "sha.value=<landing-sha> branch=<branch> rehearsal_ref=<rehearsal-run-id> watermark=#{@watermark}",
               "rehearsal_verdict.value=#{@verdict.verdict} refusal_total=0 ledger_dir=#{@held.directory}"]
            end

            # The owner's confirmation, unless the auto-mint rule lets the mint run without it.
            def confirm?
              from = @latest[:label]
              facts = { verdict: @verdict, from: from }.merge(QaAutoMint.edge_facts(@held, @held.directory, from))
              !QaAutoMint.held_reason(facts, refusal_total: 0).nil?
            end
          end
        end
      end
    end
  end
end
