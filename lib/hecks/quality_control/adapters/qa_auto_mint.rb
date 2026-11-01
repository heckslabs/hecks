# frozen_string_literal: true

require "pg"
require_relative "qa_era_mint"
require_relative "../../adapters/driven/postgres_era/lineage_manager/mint_decision"

module Hecks
  module Adapters
    # The auto-mint rule the Maintenance mint enforces. A mint runs without the owner's confirm only
    # when
    # the edge leaving the held era is empty, every change in the shape diff is additive, and the
    # rehearsal
    # refused nothing. The rule is declared as `AutoMintAdditive` in quality_control.bluebook; this
    # module
    # is its check. The stranded-marker and watermark guards stay in `MainMaintenance#mint`.
    module QaAutoMint
      # The edge file's opening line and its closing line, with nothing between them when it is
      # empty.
      EDGE_HEADER = /\AHecks\.data_translation\s+"[^"]*",\s+from:\s+"[^"]*",\s+to:\s+"[^"]*"\s+do\z/

      module_function

      # The facts the rule reads from a ledger: its live watermark, the edge leaving its held era
      # and that edge's text, and the verdict the shared mint decision reaches for the held era.
      #
      # @param ledger [String] the bluebook directory of the ledger
      # @return [Hash] `watermark`, `from`, `to`, `edge_text`, `verdict`, `held` and `current`
      def facts(ledger)
        held = JournalStore::HeldDomain.open(ledger, mode: :translated)
        registry = held.registry
        latest, watermark = latest_era(held)
        verdict = PostgresEra::LineageManager::MintDecision.decide_latest(
          latest, bluebook: held.bluebook, translations: registry.translations, directory: ledger, watermark: watermark
        )
        { watermark: watermark, held: held_declaration(latest), current: held.bluebook, verdict: verdict }
          .merge(edge_facts(held, ledger, latest[:label]))
      end

      # @return [Array(Hash, Integer)] the latest held era and the live watermark, read from its
      #   database
      def latest_era(held)
        db = PostgresEra.connect_for(held.domain_name, held.settings)
        lineage = PostgresEra::Lineage.new(db, held.domain_name)
        [lineage.eras.last, lineage.last_ordinal]
      ensure
        db&.close
      end

      # @return [Bluebook::Declaration, nil] the declaration the held era holds, or nil when its
      #   held text does not declare the shape its mint recorded (`MintDecision.held_for_decision`)
      def held_declaration(latest) = PostgresEra::LineageManager::MintDecision.held_for_decision(latest)[:declaration]

      # The bluebook directory a mint is for: the one the request names, or the QualityControl
      # ledger.
      #
      # @return [String]
      def ledger_for(root, requested) = requested || File.join(root, QaEraMint::LEDGER)

      # @return [String, nil] the reason the live watermark moved from the rehearsed one, or nil
      def stale_watermark(rehearsed, live)
        "the ledger watermark moved from #{rehearsed} to #{live} since the rehearsal; rehearse again" unless rehearsed == live
      end

      # Why the auto-mint rule holds a mint for the owner, or nil when it lets the mint run
      # unconfirmed. With no edge file, the implicit empty edge stands in for an empty edge when
      # the shape change qualifies for one.
      #
      # @param facts [Hash] what `facts` read from the ledger
      # @param refusal_total [Integer, nil] the rehearsal's refusal count
      # @return [String, nil] the reason the owner must approve, or nil when the rule holds
      def held_reason(facts, refusal_total:)
        edge_reason(facts) || additive_reason(facts) || rehearsal_reason(refusal_total)
      end

      # @return [String, nil] why the edge leaving the held era does not stand in for an empty one
      def edge_reason(facts)
        return "no translation edge leaves #{facts[:from]}" if facts[:edge_text].nil? && !implicit?(facts)
        return "the edge from #{facts[:from]} is not empty" if facts[:edge_text] && !empty_edge?(facts[:edge_text])

        nil
      end

      # @return [String, nil] why the shared decision does not take the shape change as additive
      def additive_reason(facts)
        case facts[:verdict].reason
        when :non_qualifying then "the shape change is not additive"
        when :unrecorded then "the move from #{facts[:from]} to #{facts[:to]} is not recorded"
        when :partial_held_text then "the held era #{facts[:from]} holds part of its domain's source, so the move needs an edge"
        end
      end

      # @return [String, nil] why the rehearsal refused rows
      def rehearsal_reason(refusal_total)
        return if refusal_total.is_a?(Integer) && refusal_total.zero?

        "the rehearsal refused #{refusal_total.inspect} rows"
      end

      # Whether an edge file declares nothing: its header and its `end`, with no line between them.
      #
      # @param text [String] the edge file's text
      # @return [Boolean]
      def empty_edge?(text)
        body = text.lines.map(&:strip).reject { |line| line.empty? || line.start_with?("#") }
        body.size == 2 && EDGE_HEADER.match?(body.first) && body.last == "end"
      end

      # Whether no edge file is needed: the shared decision takes the implicit empty edge.
      #
      # @return [Boolean]
      def implicit?(facts) = facts[:verdict].verdict == "would_mint" && facts[:verdict].source == "implicit"

      # @return [Hash] the edge leaving the held era's label for the current shape's label, and its
      #   text
      def edge_facts(held, ledger, from)
        to = Runtime::StorageShape.mint_hash(held.bluebook)[0, Runtime::StorageShape::LABEL_LENGTH]
        { from: from, to: to, edge_text: edge_text(File.join(ledger, "translations"), from, to) }
      end

      # The text of the edge that leads from `from` to `to`, found by its header.
      #
      # @return [String, nil]
      def edge_text(dir, from, to)
        header = %(from: "#{from}", to: "#{to}")
        Dir.glob(File.join(dir, "*.bluebook")).map { |path| File.read(path) }.find { |text| header_of(text).include?(header) }
      end

      # @return [String] the first line of an edge file, where its source and target are named
      def header_of(text) = text.lines.first.to_s
    end
  end
end
