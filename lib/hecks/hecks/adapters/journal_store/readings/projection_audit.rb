# frozen_string_literal: true

require "json"
require "hecks/ports/persistence/plugins/era"

module Hecks
  module Adapters
    class JournalStore
      module Readings
        # Whether each era's stored hash is the hash of its stored projection. A held projection is
        # trusted to say what shape an era holds, so one that was edited, copied from another era or
        # written for another bluebook leaves the era's name describing a shape it does not hold.
        # The reading only selects: it recomputes `ProjectedBluebook#mint_hash` and compares.
        module ProjectionAudit
          # Every bluebook under a domain directory, each against the database its own world names.
          #
          # @param domain [Hash, String] the domain directory
          # @return [Hash] `text:` the audit as JSON: the eras read and each mismatch found
          # @raise [Runtime::NotFound] if the directory cannot be loaded or a database refuses
          def projection_audit(domain:)
            answering do
              directory = plain(domain)
              registry = Hecks.describe(directory).registry
              rows = registry.bluebooks.each_key.flat_map { |name| ProjectionAudit.of(registry, directory, name) }
              JSON.pretty_generate({ "domain" => directory, "mismatches" => rows })
            end
          end

          # @param registry [Runtime::Registry] a described registry
          # @param directory [String] the domain's bluebook directory
          # @param name [String] the bluebook's name
          # @return [Array<Hash>] one row per era whose hash differs from its projection's
          def self.of(registry, directory, name)
            held = HeldDomain.new(registry, directory, name)
            return [] unless held.capable?

            held.reading { |lineage| mismatches(name, held.held_eras(lineage)) }
          end

          # @param domain [String] the domain's name
          # @param eras [Array<Hash>] eras as `Lineage#eras` answers them
          # @return [Array<Hash>] `domain`, `ordinal`, `stored` hash and `recomputed` hash of each
          #   era whose projection hashes to another value; an era without both is skipped
          def self.mismatches(domain, eras)
            eras.filter_map do |era|
              recomputed = recomputed_hash(era)
              next if recomputed.nil? || recomputed == era[:hash]

              { "domain" => domain, "ordinal" => era[:ordinal], "stored" => era[:hash], "recomputed" => recomputed }
            end
          end

          # @param era [Hash] an era with `hash` and `projection`
          # @return [String, nil] the hash of the stored projection; nil when the era lacks either
          def self.recomputed_hash(era)
            return unless era[:hash] && era[:projection]

            Runtime::ProjectedBluebook.new(era[:projection]).mint_hash
          end
        end
      end
    end
  end
end
