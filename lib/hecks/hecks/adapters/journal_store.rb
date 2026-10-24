# frozen_string_literal: true

require_relative "journal_store/examination"
require_relative "journal_store/changes"
require_relative "journal_store/readings"

module Hecks
  module Adapters
    # The `JournalStore` port's adapter: reaches the era plugin and the persistence adapters on an
    # operator's behalf, to examine a domain's journal, change it, or read how it stands.
    #
    # `examine` reports the facts Custodian's `Era.Permit` holds against the request, `apply` makes
    # an admitted change, and the queries (`scaffold_translation`, `audit_translation`,
    # `attestation`, `compaction`) answer without writing. Every method reuses the era plugin's
    # own logic (`LineageManager`, `Lineage`, `Translation::*`); only the entry point moved.
    #
    # Arguments arrive materialized, so a value object is `{ value: x }`.
    class JournalStore
      include Examination
      include Changes
      include Readings

      # Accepts the arguments every driven adapter is built with and keeps none of them.
      #
      # @param aggregate [Object, nil] unused
      # @param settings [Hash] unused
      # @param root [String, nil] unused
      def initialize(aggregate: nil, settings: {}, root: nil); end

      private

      def plain(argument) = argument.is_a?(Hash) ? argument[:value] : argument

      # Aggregate names, from the comma-separated list a request carries.
      def names(list) = Text.comma_list(plain(list))

      # The name of the bluebook a held domain loaded.
      def domain_name(domain)
        bluebook = domain.bluebook
        bluebook.name
      end

      # The aggregates a held domain's bluebook declares.
      def aggregates_of(domain)
        bluebook = domain.bluebook
        bluebook.aggregates
      end

      # The translation edges a held domain's registry holds.
      def translations_of(domain)
        registry = domain.registry
        registry.translations
      end

      # `id:old,id:new` as the map the tail merge takes; the side is what follows the last colon.
      def winners(held)
        plain(held[:winners]).to_s.split(",").to_h do |pair|
          id, _, side = pair.rpartition(":")
          [id, side]
        end
      end

      # The era as stored, digest unchecked: a text that drifted is what re-attesting is for.
      def raw_era(domain, lineage, ordinal)
        present = lineage.db.exec("SELECT to_regclass('hecks_eras') AS present")[0]["present"]
        (present && lineage.raw_era(ordinal)) or
          raise Runtime::NotFound, "#{domain_name(domain)} holds no era #{ordinal}"
      end
    end
  end
end
