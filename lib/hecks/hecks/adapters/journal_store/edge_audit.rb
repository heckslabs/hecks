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
        # What one audit found: the audited `edge`, how many edges are `leaving` the latest held
        # era, whether it is `ok`, the `report` text, every refusal (`Aggregate#id: wording`) and
        # the records as translated (`after`), by aggregate name and id.
        Finding = Struct.new(:edge, :leaving, :ok, :report, :refusals, :after, keyword_init: true)

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
          @bluebook = held.bluebook
          @registry = held.registry
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
          chain = @manager.edge_chain(@registry, @bluebook, @eras[0..-2], latest[:label])
          finding(chain, latest[:ordinal], 1)
        end

        # The shape not yet minted: the edge that leaves the latest era for the current shape.
        def pending(latest)
          label = Runtime::StorageShape.mint_hash(@bluebook)[0, Runtime::StorageShape::LABEL_LENGTH]
          leaving = leaving_edges(latest)
          edge = edge_to(leaving, latest, label)
          chain = @manager.edge_chain(@registry, @bluebook, @eras[0..-2] + [latest], label)
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
          domain = @bluebook.name
          @registry.translations.select { |t| t.domain == domain && t.from == latest[:label] }
        end

        def finding(chain, era, leaving, edge = chain.last[:translation])
          audits = @bluebook.aggregates.map { |aggregate| [aggregate, *verdict_for(aggregate, edge, era, chain)] }
          lines = audits.flat_map { |aggregate, verdict, records, _| describe(aggregate, edge, verdict, records) }
          refusals = audits.flat_map { |_, verdict, _, _| verdict.violations }
          Finding.new(edge: edge, leaving: leaving, ok: refusals.empty?, report: lines.join("\n"),
                      refusals: refusals, after: audits.to_h { |aggregate, _, _, after| [aggregate.name, after] })
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
          [verdict, after.size, after]
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
          "── #{@bluebook.name}::#{aggregate.name} (edge #{edge.from} → #{edge.to}, " \
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
