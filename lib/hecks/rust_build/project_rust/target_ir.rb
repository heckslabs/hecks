# frozen_string_literal: true

require "json"

module Hecks
  module RustBuild
    class ProjectRust
      # The target domain's IR, with the binding facts that ride beside it (they are not shape
      # facts, so `bluebook.to_h` never mentions them).
      class TargetIr
        # The optional attachments `rust/host` reads from `ir.json`, each omitted when nothing
        # attached provides it: exporter method, then the key it is written under.
        SEAMS = %i[authorization membership identity newsletter newsletter_issues payments
                   registrations payment_connection checkout].freeze

        # Round-trips a value through JSON so generators see the string-keyed shape a real
        # `ir.json` carries, never live Ruby symbols.
        #
        # @param payload [Object] a JSON-compatible value
        # @return [Object] the same value with symbol keys, as parsed from JSON
        def self.json_shaped(payload) = JSON.parse(JSON.generate(payload), symbolize_names: true)

        # @param registry [Hecks::Runtime::Registry] the loaded registry
        # @param domain_name [String] the target bluebook's name
        # @param bluebook_dir [String] the target's `bluebook/` directory
        def initialize(registry, domain_name, bluebook_dir)
          @registry = registry
          @domain_name = domain_name
          @bluebook_dir = bluebook_dir
        end

        # @return [Hash{Symbol => Object}] the IR the generator reads
        # @raise [Failure] when the domain provides membership but not identity
        def call
          exporter = Hecks::Projector::Exporter
          ir = shaped(exporter.call(@registry).fetch(@domain_name))
          ir[:lineage] = shaped(exporter.lineage(@registry, @domain_name))
          ir[:persistence] = shaped(exporter.persistence(@registry, @domain_name))
          add_seams(ir, exporter)
          add_edges_and_source(ir)
          ir
        end

        private

        def shaped(payload) = self.class.json_shaped(payload)

        def add_seams(document, exporter)
          seams = SEAMS.to_h { |seam| [seam, exporter.public_send(seam, @registry, @domain_name)] }
          seams.each { |seam, value| document[seam] = shaped(value) unless value.empty? }
          return unless !seams[:membership].empty? && seams[:identity].empty?

          raise Failure, "#{@domain_name} provides membership but not identity — rust/host Google sign-in " \
                         "cannot register or link an identity from ir.json. Attach Identity " \
                         "(`attaches \"Identity\"` plus a sibling Hecks.hecksagon \"Identity\") so the " \
                         "hecksagon, not a deploy-time guess, names the identity verbs."
        end

        # Edges carry their own precompiled SQL, so a boot-time mint only executes it. Committed
        # approvals sit beside the edges. The source text is verbatim: the era's integrity digest is
        # the SHA256 of it, not of anything re-derived from the parsed IR.
        def add_edges_and_source(document)
          edges = Hecks::Projector::Exporter.translations(@registry).select { |edge| edge[:domain] == @domain_name }
          document[:translations] = shaped(edges)
          approvals = Hecks::Translation::ApprovalFile.read_all(@bluebook_dir)
          document[:approvals] = shaped(approvals) unless approvals.empty?
          document[:source_text] = Hecks::Runtime::EraCheck.source_text_for(
            @registry.bluebooks.fetch(@domain_name), @bluebook_dir, registry: @registry
          )
        end
      end
    end
  end
end
