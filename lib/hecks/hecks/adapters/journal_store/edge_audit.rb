# frozen_string_literal: true

require "json"
require_relative "held_domain"

module Hecks
  module Adapters
    class JournalStore
      # The translation audit of the edge that leads a domain's latest held era to its current
      # shape, without holding or naming anything: an era that has no name yet is named in memory.
      #
      # It answers what the audit's three layers found, as the report `hecks audit_translation`
      # prints, and the edge itself, so approving it audits the very edge that was read.
      class EdgeAudit
        # What one audit found.
        #
        # @!attribute [r] edge
        #   @return [Bluebook::Translation] the audited edge
        # @!attribute [r] leaving
        #   @return [Integer] how many edges leave the latest held era
        # @!attribute [r] ok
        #   @return [Boolean] whether no layer refused
        # @!attribute [r] report
        #   @return [String] the report, one block per aggregate
        Finding = Struct.new(:edge, :leaving, :ok, :report, keyword_init: true)

        # Audits the edge that leaves the latest held era.
        #
        # @param held [HeldDomain] the loaded domain, translation edges included
        # @param lineage [Lineage] the domain's lineage
        # @param eras [Array<Hash>] the eras the lineage holds, at least one
        # @return [Finding, nil] the finding; nil when the domain stands at era 1, with no edge
        # @raise [Runtime::NotFound] if no edge leads the latest era to the current shape, or a
        #   preview query is refused by Postgres
        def self.call(held, lineage, eras)
          new(held, lineage, eras).call
        end

        # @param held [HeldDomain] the loaded domain
        # @param lineage [Lineage] the domain's lineage
        # @param eras [Array<Hash>] the held eras
        def initialize(held, lineage, eras)
          @held = held
          @lineage = lineage
          @eras = eras
          @manager = PostgresEra::LineageManager
        end

        # @return [Finding, nil] see `EdgeAudit.call`
        def call
          latest = @held.named(@eras.last)
          if @held.shape == Runtime::StorageShape.project(@manager.shadow(latest[:held_text]))
            return nil if latest[:ordinal] == 1

            settled(latest)
          else
            pending(latest)
          end
        end

        private

        # The shape already minted: the edge that arrives at the latest era.
        def settled(latest)
          chain = @manager.edge_chain(@held.registry, @held.bluebook, @eras[0..-2], latest[:label])
          finding(chain, latest[:ordinal], 1)
        end

        # The shape not yet minted: the edge that leaves the latest era for the current shape.
        def pending(latest)
          label = Runtime::StorageShape.mint_hash(@held.bluebook)[0, Runtime::StorageShape::LABEL_LENGTH]
          leaving = leaving_edges(latest)
          edge = edge_to(leaving, latest, label)
          chain = @manager.edge_chain(@held.registry, @held.bluebook, @eras[0..-2] + [latest], label)
          finding(chain, latest[:ordinal] + 1, leaving.size, edge)
        end

        # The leaving edge that arrives at the current shape.
        def edge_to(leaving, latest, label)
          leaving.find { |t| t.to == label } or
            raise Runtime::NotFound, "no translation edge leads #{latest[:label]} to #{label} — " \
                                     "run `hecks scaffold_translation` first"
        end

        # The registered translations that leave the latest era.
        def leaving_edges(latest)
          domain = @held.bluebook.name
          @held.registry.translations.select { |t| t.domain == domain && t.from == latest[:label] }
        end

        def finding(chain, era, leaving, edge = chain.last[:translation])
          lines = []
          ok = true
          @held.bluebook.aggregates.each do |aggregate|
            verdict, records = verdict_for(aggregate, edge, era, chain)
            lines.concat(describe(aggregate, edge, verdict, records))
            ok &&= verdict.ok?
          end
          Finding.new(edge: edge, leaving: leaving, ok: ok, report: lines.join("\n"))
        end

        def verdict_for(aggregate, edge, era, chain)
          after = translated(aggregate, era, chain)
          before = if chain.size > 1
                     translated(aggregate, era, chain[0..-2])
                   else
                     @lineage.ancestor_latest(aggregate, era, chain)
                   end
          verdict = Translation::Audit.check(aggregate: aggregate, declared: edge.for_aggregate(aggregate.name),
                                             before: before, after: after)
          [verdict, after.size]
        end

        def translated(aggregate, era, chain)
          @lineage.translated_latest(aggregate, era, chain)
        rescue PG::Error => e
          raise Runtime::NotFound, "REFUSED: #{e.message.strip}"
        end

        def describe(aggregate, edge, verdict, records)
          [heading_line(aggregate, edge, records), *verdict_lines(verdict),
           *verdict.samples.flat_map { |sample| sample_lines(sample) }]
        end

        def heading_line(aggregate, edge, records)
          "── #{@held.bluebook.name}::#{aggregate.name} (edge #{edge.from} → #{edge.to}, " \
            "#{records} record#{"s" unless records == 1})"
        end

        # What the audit found wrong with, or dropped from, the translated records.
        def verdict_lines(verdict)
          lines = verdict.violations.map { |violation| "   REFUSED: #{violation}" }
          lines << "   dropped (declared data loss): #{verdict.dropped.join(", ")}" unless verdict.dropped.empty?
          unless verdict.unfed.empty?
            lines << "   unfed (no rule, no default — add default: if required): #{verdict.unfed.join(", ")}"
          end
          lines
        end

        def sample_lines(sample)
          lines = ["   ##{sample[:id]}"]
          lines << "     before: #{JSON.generate(sample[:before])}" if sample[:before]
          lines << "     after:  #{JSON.generate(sample[:after])}" if sample[:after]
          lines
        end
      end
    end
  end
end
