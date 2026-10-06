# frozen_string_literal: true

require "hecks"
# The audit reads the era persistence plugin's lineage journal and its audit machinery (ADR 0033).
require "hecks/ports/persistence/plugins/era"
require "json"
require_relative "../tools"
require_relative "translation_audit/domain_loading"
require_relative "translation_audit/edges"
require_relative "translation_audit/verdicts"

module Hecks
  module Tools
    # Runs the translation audit's three layers standalone against a domain's latest or pending
    # edge. Read-only except `--approve`, which records the human approval in the database.
    #
    #   hecks audit_translation <domain> [--approve]
    module TranslationAudit
      # What one audit run works on: the loaded domain, its open journal, and whether `--approve`
      # was given.
      Session = Struct.new(:registry, :bluebook, :directory, :db, :lineage, :approve)

      extend DomainLoading
      extend Edges
      extend Verdicts

      module_function

      # Audits the edge and prints each aggregate's verdict and samples.
      #
      # @param argv [Array<String>] the domain directory, and `--approve` to record approval
      # @param root [String] unused: the domain is read from the path given
      # @return [Integer] 0 when the audit passes or there is no edge, 1 when it is refused
      # @raise [SystemExit] when the domain cannot be loaded or is not lineage-capable
      def main(argv, **)
        argv = argv.dup
        approve = argv.delete("--approve")
        domain_path = argv.shift or abort "usage: hecks audit_translation <domain> [--approve]"

        registry, bluebook, directory = load_domain(domain_path)
        db, lineage = open_lineage(registry, bluebook)
        audit(Session.new(registry, bluebook, directory, db, lineage, approve))
      end

      # @param session [Session] the loaded domain and its open journal
      # @return [Integer] the exit status
      def audit(session)
        return hold_first_era(session) if session.lineage.eras.empty?

        audit_edge(session, edge_chain(session.registry, session.bluebook, session.lineage))
      end

      # @param found [Array, nil] the era ordinal and the chain of translations ending in it, or nil
      #   when there is no edge
      # @return [Integer] the exit status
      def audit_edge(session, found)
        era, chain = found
        return 0 unless era

        edge = chain.last[:translation]
        failed = report(session.bluebook, session.lineage, edge, era, chain)
        conclude(session.db, session.lineage, edge, failed, session.approve)
      end

      # A journal with no era yet holds the bluebook as its first, so there is no edge to audit.
      #
      # @return [Integer] the exit status, 0
      def hold_first_era(session)
        session.lineage.hold_first!(Hecks::Runtime::EraCheck.source_text_for(session.bluebook, session.directory),
                                    projection: Hecks::Runtime::StorageShape.project(session.bluebook))
        puts "#{session.bluebook.name} held era 1 just now — no edge to audit."
        session.db.close
        0
      end
    end
  end
end
