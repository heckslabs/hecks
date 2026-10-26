# frozen_string_literal: true

require "hecks"
require_relative "ledger/chain"
require_relative "ledger/journal"

module Hecks
  module Adapters
    # The `Ledger` port's adapter: seals the hash chain of a domain's append-only journals before
    # compaction removes rows from them, and walks the chain again to show the journals were not
    # rewritten.
    #
    # Each journal keeps its seals beside it (`ledger_anchors`, `record_ledger_anchor`), so a
    # sealed head can be compared with the journal it protects and a compaction cannot take the
    # evidence of what it removed along with it. A journal an adapter does not chain (Memory, the
    # era journal, which the database already protects) is left out.
    #
    # Arguments arrive materialized, so a value object is `{ value: x }`.
    class Ledger
      # Accepts the arguments every driven adapter is built with and keeps none of them.
      #
      # @param aggregate [Object, nil] unused
      # @param settings [Hash] unused
      # @param root [String, nil] unused
      def initialize(aggregate: nil, settings: {}, root: nil); end

      # Seals every chained journal of a domain at its present end.
      #
      # @param held [Hash] the `Era` record of a compaction: `domain`
      # @return [Hash{Symbol => Hash}] `domain:` as asked, `through:` the entries sealed in all,
      #   `head:` one digest for the journals' sealed heads and `previous:` the same for the seals
      #   before them
      # @raise [Runtime::NotFound] if the domain directory does not exist
      # @raise [Runtime::WiringError] if the domain has no chained journal with entries
      def capture(**held)
        domain = plain(held[:domain])
        points = journals(domain).filter_map(&:seal)
        raise Runtime::WiringError, "no journal entries to seal" if points.empty?

        {
          domain:   { value: domain },
          through:  { value: points.sum { |point| point[:through] } },
          head:     { value: Chain.summary(points, :head) },
          previous: { value: Chain.summary(points, :previous) }
        }
      end

      # Walks every chained journal from its first seal and compares each seal with the journal.
      #
      # @param held [Hash] the `Audit` record: `domain`
      # @return [Hash{Symbol => Hash}] `checked:` the seals and entries compared, `report:` what
      #   was found
      # @raise [Runtime::NotFound] if the domain directory does not exist
      # @raise [Runtime::WiringError] if nothing is sealed, or a seal does not match its journal
      def walk(**held)
        sealed = journals(plain(held[:domain])).select(&:sealed?)
        raise Runtime::WiringError, "nothing is sealed yet: the chain cannot be shown intact" if sealed.empty?

        counts = sealed.map(&:verify)
        report(sealed.size, counts.sum { |count| count[:seals] }, counts.sum { |count| count[:entries] })
      end

      private

      def plain(argument) = argument.is_a?(Hash) ? argument[:value] : argument

      def report(journals, seals, entries)
        text = "#{journals} journal#{"s" unless journals == 1}: #{seals} seals held, #{entries} entries re-walked"
        { checked: { value: seals + entries }, report: { value: text } }
      end

      def journals(path)
        raise Runtime::NotFound, "no such domain #{path.inspect}" unless Dir.exist?(path.to_s)

        registry = Hecks.boot(File.expand_path(path), install_driving: false).registry
        registry.bluebooks.flat_map do |domain_name, bluebook|
          bluebook.aggregates.filter_map { |aggregate| journal(registry, domain_name, aggregate) }
        end
      end

      def journal(registry, domain_name, aggregate)
        repository = registry.repository(domain_name, aggregate)
        return unless repository.is_a?(Ports::Persistence::AppendOnly)

        Journal.of(aggregate, repository.adapter)
      end
    end
  end
end
