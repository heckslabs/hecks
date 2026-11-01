# frozen_string_literal: true

require_relative "held_domain"
require_relative "../../../quality_control/adapters/qa_era_mint"
require_relative "../../../quality_control/adapters/qa_auto_mint"

module Hecks
  module Adapters
    class JournalStore
      # The Hecks domain's held mint, answered on the `JournalStore` port's `Mint`.
      #
      # It reads the domain's facts through the shared mint decision (`QaAutoMint.facts`, which
      # runs `MintDecision.decide_latest`), refuses by name whatever the decision does not allow,
      # and mints through `QaEraMint`, the mint transaction the QualityControl ledger uses. The
      # reader and the minter are injected so a spec runs with no database.
      class HeldMint
        # The Hecks domain's bluebook directory, the one a checkout boots.
        DOMAIN = File.expand_path("../..", __dir__)

        # The domain name the mint is recorded under.
        NAME = "Hecks"

        # Reads the facts a mint decides on from a bluebook directory.
        #
        # @param directory [String] the domain's bluebook directory
        # @return [Hash] `held` (the count of held eras), and when any are held, `next_era`,
        #   `watermark`, `from`, `to` and `verdict` (see `QaAutoMint.facts`)
        def self.read(directory)
          domain = HeldDomain.open(directory, mode: :translated)
          held = domain.reading { |lineage| domain.held_eras(lineage) }
          return { held: 0 } if held.empty?

          QaAutoMint.facts(directory).merge(held: held.size, next_era: held.last[:ordinal] + 1)
        end

        # Mints the era through the QualityControl mint transaction, against the Hecks domain.
        #
        # @return [Array(String, Boolean)] the minted label or the refusal, and whether it minted
        def self.mint(era, request)
          QaEraMint.call(DOMAIN, domain: NAME, era: era, request: request, ledger: DOMAIN)
        end

        # @param directory [String] the bluebook directory a mint is for
        # @param reader [#call] reads the facts of a directory; `HeldMint.read` when not given
        # @param minter [#call] mints (era, request); `HeldMint.mint` when not given
        def initialize(directory: DOMAIN, reader: nil, minter: nil)
          @directory = directory
          @reader = reader || ->(dir) { HeldMint.read(dir) }
          @minter = minter || ->(era, request) { HeldMint.mint(era, request) }
        end

        # Answers a `MintHeld` request: a minted era, a shape that did not move, or a named refusal.
        #
        # @param run [String] the run the mint belongs to
        # @param confirm [Boolean, nil] whether the mint was confirmed
        # @param rehearsal_verdict [String, nil] the verdict the caller read, when it read one
        # @param watermark [Integer, nil] the watermark the caller read, when it read one
        # @return [Hash{Symbol => Hash}] `run`, `outcome` (`minted` or `no_change`) and `label`
        # @raise [Runtime::WiringError] naming why the mint was refused
        def answer(run:, confirm: nil, rehearsal_verdict: nil, watermark: nil)
          refuse!("the mint needs --confirm") unless confirm == true
          facts = @reader.call(@directory)
          refuse!("the Hecks domain holds no era; hold its first era before a mint") if facts[:held].zero?
          return unchanged(run, facts) if facts[:from] == facts[:to]

          decide!(facts, rehearsal_verdict, watermark)
          minted(run, facts)
        end

        private

        # Refuses a mint whose decision is not `would_mint`, a rehearsal that disagrees with the
        # decision, or a watermark that moved since the rehearsal.
        def decide!(facts, rehearsal_verdict, watermark)
          verdict = facts[:verdict]
          refuse!("the decision is #{verdict.verdict}, not would_mint: #{verdict.reason}") unless verdict.verdict == "would_mint"
          refuse_rehearsal!(rehearsal_verdict)
          stale = watermark && QaAutoMint.stale_watermark(watermark, facts[:watermark])
          refuse!(stale) if stale
        end

        # Refuses a rehearsal that said anything but would_mint; a caller that read none passes nil.
        def refuse_rehearsal!(rehearsal_verdict)
          return if rehearsal_verdict.nil? || rehearsal_verdict == "would_mint"

          refuse!("the rehearsal said #{rehearsal_verdict}, not would_mint")
        end

        def unchanged(run, facts)
          { run: { value: run }, outcome: { value: "no_change" }, label: { value: facts[:to] } }
        end

        def minted(run, facts)
          request = { confirm: true, verdict: "would_mint", watermark: facts[:watermark] }
          label, ran = @minter.call(facts[:next_era], request)
          refuse!(label) unless ran
          { run: { value: run }, outcome: { value: "minted" }, label: { value: label } }
        end

        def refuse!(reason) = raise(Runtime::WiringError, reason)
      end
    end
  end
end
