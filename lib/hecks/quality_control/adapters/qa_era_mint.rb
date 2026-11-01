# frozen_string_literal: true

require_relative "../../hecks/adapters/journal_store/held_domain"

module Hecks
  module Adapters
    # The mint of the QualityControl ledger's next era, run by the Maintenance mint. The era check
    # of the ledger the QA world names runs once with the mint command's request. The world keeps
    # `mint_eras false`; this one check's settings carry `mint_eras true` and the request, which is
    # the one-mint permission the world's comment describes.
    module QaEraMint
      # The ledger's bluebook directory, under the repository root.
      LEDGER = "qa/bluebook"

      module_function

      # Mints the next era of the ledger, or refuses by name.
      #
      # @param root [String] the repository root holding `qa/bluebook`
      # @param domain [String] the domain the mint is for; the ledger must hold it
      # @param era [Integer] the ordinal the mint is for; it must be the era the ledger would mint
      #   next
      # @param request [Hash] the mint command's request: `confirm` (a boolean), `verdict` (the
      #   rehearsal's verdict) and `watermark` (the ledger watermark the rehearsal read)
      # @return [Array(String, Boolean)] the minted era's label or the refusal, and whether it
      #   minted
      def call(root, domain:, era:, request:)
        held = JournalStore::HeldDomain.open(File.join(root, LEDGER), mode: :translated)
        settings = held.settings.merge(mint_eras: true, mint_request: request)
        refuse_wrong_mint!(held, settings, domain, era)
        mint!(held, settings) ? [Runtime::StorageShape.mint_label(held.bluebook), true] : [unminted, false]
      rescue Runtime::WiringError, Runtime::NotFound => e
        [e.message, false]
      end

      # Refuses a mint that names another domain, or an era other than the one the ledger would mint
      # next.
      #
      # @return [void]
      # @raise [Runtime::WiringError] naming the mismatch
      def refuse_wrong_mint!(held, settings, domain, era)
        name = held.domain_name
        raise Runtime::WiringError, "the ledger holds #{name}, not #{domain}" unless name == domain

        next_era = next_era_of(settings, name)
        return if next_era == era

        raise Runtime::WiringError, "the mint names era #{era}, but the ledger's next era is #{next_era}"
      end

      # @return [Integer] the ordinal the ledger would mint next: one past its latest held era
      def next_era_of(settings, name)
        db = PostgresEra.connect_for(name, settings)
        latest = PostgresEra::Lineage.new(db, name).eras.last
        latest ? latest[:ordinal] + 1 : 1
      ensure
        db&.close
      end

      # Runs the era check with the request. It mints when the shape drifted, and answers false when
      # the shape is already the ledger's current one.
      #
      # @return [Integer, nil] the ordinal minted, or nil when nothing minted
      def mint!(held, settings)
        text = Runtime::EraCheck.source_text_for(held.bluebook, held.directory, registry: held.registry) ||
               Runtime::EraCheck.refuse_missing_source!(held.bluebook, held.directory)
        held.registry.adapter_class(held.adapter_name).era_check!(
          registry: held.registry, bluebook: held.bluebook, current_text: text, settings: settings,
          directory: held.directory
        )
      end

      # @return [String] the refusal for a mint that found nothing to mint
      def unminted = "the ledger already holds the current shape; no era was minted"
    end
  end
end
