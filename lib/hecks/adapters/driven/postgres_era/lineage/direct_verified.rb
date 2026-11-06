require "json"
require "digest"

module Hecks
  module Adapters
    class PostgresRevisions
      class Lineage
        # The edge chains whose composed (direct) translation `direct_translation_spec` proves
        # equal to their one-link-per-era chain, kept as fingerprints in `direct_verified.json`.
        #
        # A fingerprint is the bluebook name and, for each edge in order, its origin, its target
        # and a digest of its rules. A client chain that shares a name with a proven one but
        # differs in any edge reads through the chain. A stale file only costs the direct path.
        #
        # Rewrite the file after a committed edge changes by running the generator spec:
        #
        #     HECKS_WRITE_DIRECT_VERIFIED=1 exe/hecks test_suite_run.run_spec_example! \
        #       file.value=spec/adapters/driven/postgres_era/direct_verified_spec.rb \
        #       "example.value= " --wait
        module DirectVerified
          PATH = File.join(__dir__, "direct_verified.json").freeze

          module_function

          # @param translations [Array<Bluebook::Translation>] a chain of edges, oldest first
          # @return [String] the chain's fingerprint, SHA-256 hex
          def fingerprint(translations)
            edges = translations.map { |edge| [edge.from.to_s, edge.to.to_s, rules_digest(edge)] }
            Digest::SHA256.hexdigest(JSON.generate([translations.first&.domain.to_s, edges]))
          end

          # @param translations [Array<Bluebook::Translation>] a chain of edges, oldest first
          # @return [Boolean] whether this exact chain is one the spec proved
          def proven?(translations)
            return false if translations.empty? || translations.any?(&:nil?)

            proven.include?(fingerprint(translations))
          rescue StandardError
            false
          end

          # @return [Array<String>] the proven fingerprints in the committed file; empty if it is
          #   missing or unreadable
          def proven
            JSON.parse(File.read(PATH)).fetch("chains", []).map { |chain| chain["fingerprint"] }
          rescue SystemCallError, JSON::ParserError
            []
          end

          # @param chains [Array<Array>] each `[domain, start label, final label, edges]` proved
          # @return [String] the file's JSON text for those chains
          def render(chains)
            rows = chains.map do |domain, start, final, edges|
              { "domain" => domain, "from" => start.to_s, "to" => final.to_s, "fingerprint" => fingerprint(edges) }
            end
            ordered = rows.uniq.sort_by { |row| row.values_at("domain", "from", "to", "fingerprint") }
            "#{JSON.pretty_generate("chains" => ordered)}\n"
          end

          def rules_digest(edge) = Digest::SHA256.hexdigest(JSON.generate(edge.to_plan))
        end
      end
    end
  end
end
