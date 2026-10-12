# frozen_string_literal: true

module Hecks
  module Adapters
    module Rehearsal
      # What a data copy holds for the domain, counted before any audit runs: the eras, the rows
      # each aggregate's head holds, and the entries and live records of the journal.
      #
      # The mint's audit reads the journal (the latest entry of each record), never the head, so
      # the two counts sit side by side and a divergence between them is visible, not refused.
      Census = Struct.new(:schema, :source, :present, :eras, :journal_entries, :counts, :elsewhere,
                          keyword_init: true) do
        # One aggregate's rows: what its head holds and what the journal's latest entries hold.
        const_set(:Count, Struct.new(:aggregate, :head, :journal, keyword_init: true))

        # @return [Array<String>] other schemas of the copy that hold a lineage
        def elsewhere = self[:elsewhere] || []

        # @return [Integer] the rows the heads hold, over every aggregate
        def head_rows = counts.sum(&:head)

        # @return [Integer] the live records the journal's latest entries hold
        def journal_rows = counts.sum(&:journal)

        # @return [Boolean] whether the copy holds no row of the domain at all
        def empty? = head_rows.zero? && journal_rows.zero? && journal_entries.zero?

        # @param domain [String] the domain's name, for the sentence
        # @return [String] what the copy holds, in words
        def summary(domain)
          "the copy holds #{eras} era(s), #{head_rows} head rows and #{journal_rows} journal records for " \
            "#{domain} in schema #{schema}"
        end

        # @param domain [String] the domain's name, for the sentence
        # @return [String] why a copy that holds no row cannot be rehearsed, and what to set
        def refusal(domain)
          held = eras.zero? ? "no era and no rows" : "#{eras} era(s) but no rows"
          where = if source == "memory"
                    "in the `rows` document"
                  else
                    "in schema #{schema}#{" (not in the copy)" unless present}"
                  end
          "the copy holds #{held} for domain #{domain} #{where}: #{remedy}#{hint}"
        end

        # @return [Hash] the report facts, as the `RehearsalRun` commands take them
        def facts
          { schema_used: { name: schema, source: source, present: present }, eras_held: { value: eras },
            journal_entries: { value: journal_entries }, head_rows: { value: head_rows }, census: counts.map(&:to_h) }
        end

        private

        def where
          return "in the `rows` document" if source == "memory"

          "in schema #{schema}#{" (not in the copy)" unless present}"
        end

        def remedy
          return "name the document that holds the stored records in `rows`" if source == "memory"

          "set the schema in the world file (`rehearsed_by` { schema \"...\" })"
        end

        def hint = elsewhere.empty? ? "" : "; schemas in this copy that hold a lineage: #{elsewhere.join(", ")}"
      end
    end
  end
end
