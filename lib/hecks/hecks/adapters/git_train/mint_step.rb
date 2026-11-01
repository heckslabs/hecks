# frozen_string_literal: true

require_relative "../journal_store/held_mint"

module Hecks
  module Adapters
    class GitTrain
      # The step a boarding runs before it carries anything: the Hecks domain's held mint.
      #
      # It asks `JournalStore::HeldMint`, the mint entry point `Era.MintHeld` reaches, with all
      # of its guards. A shape that did not move passes straight through, and so does a world
      # that declares `disposable_ledger true`, with no mint; a minted era is named in the
      # report, and a refusal stops the boarding with the mint's own reason before anything is
      # pushed.
      class MintStep
        # @param mint [#answer] answers `answer(run:, confirm:)` as `HeldMint#answer` does;
        #   `HeldMint.new` when not given
        def initialize(mint: nil)
          @mint = mint || JournalStore::HeldMint.new
        end

        # Runs the mint for one boarding.
        #
        # @param run [String] the boarding's run key, which the mint is recorded under
        # @param confirm [Boolean, nil] whether the boarding was confirmed
        # @return [String] what the mint did, for the boarding's report
        # @raise [Runtime::WiringError] naming the mint's refusal
        def run(run:, confirm:)
          answer = @mint.answer(run: run, confirm: confirm)
          report(answer.dig(:outcome, :value), answer.dig(:label, :value))
        rescue Runtime::WiringError => e
          raise Runtime::WiringError, "the Hecks mint refused this boarding, so nothing was pushed: #{e.message}"
        end

        private

        def report(outcome, label)
          return "the Hecks ledger is disposable, so no mint is needed" if outcome == "disposable"

          outcome == "minted" ? "the Hecks mint minted #{label}" : "the Hecks shape #{label} did not move"
        end
      end
    end
  end
end
