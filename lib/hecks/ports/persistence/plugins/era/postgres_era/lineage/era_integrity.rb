require_relative "../../era_tamper"
require_relative "../../../../../../runtime/registry"

module Hecks
  module Adapters
    class PostgresEra
      class Lineage
        # Era text integrity: each held text is verified against its stored digest before use,
        # and a drifted digest is resolved only by an append-only attestation.
        module EraIntegrity
          # The DDL for the append-only attestation record.
          CREATE_ATTESTATIONS_SQL = <<~SQL.freeze
            CREATE TABLE IF NOT EXISTS hecks_attestations (
              domain      text NOT NULL,
              ordinal     int  NOT NULL,
              old_digest  text,
              new_digest  text NOT NULL,
              attested_at timestamptz NOT NULL DEFAULT now()
            )
          SQL

          # Skips the integrity check `eras` runs, so hecks reattest can show the raw row first.
          def raw_era(ordinal)
            rows = @db.exec_params(
              "SELECT held_text, held_digest, hash, held_projection::text FROM hecks_eras WHERE domain = $1 AND ordinal = $2",
              [@domain, ordinal]
            )
            return nil if rows.ntuples.zero?

            { held_text: rows[0]["held_text"], held_digest: rows[0]["held_digest"], hash: rows[0]["hash"],
              held_projection: rows[0]["held_projection"] }
          end

          # Resolves drift via an append-only attestation record — never patch the digest.
          def reattest!(ordinal)
            era = raw_era(ordinal)
            raise Runtime::WiringError, "#{@domain} holds no era #{ordinal} to re-attest" unless era

            fresh = Digest::SHA256.hexdigest(era[:held_text])
            @db.exec(CREATE_ATTESTATIONS_SQL)
            record_attestation!(ordinal, era[:held_digest], fresh)
            adopt_digest!(ordinal, fresh)
            archive_text!(ordinal, era[:held_text])
            fresh
          end

          # A row with no stored digest yet is backfilled, not refused; only a mismatch raises.
          def verify_integrity!(ordinal, text, stored_digest, stored_projection_json)
            digest = Digest::SHA256.hexdigest(text)
            store_missing_digest!(ordinal, digest) if stored_digest.nil?
            unless stored_digest.nil? || stored_digest == digest
              raise Runtime::WiringError, Runtime::EraTamper.refusal(domain: @domain, ordinal: ordinal)
            end

            backfill_frozen_facts!(ordinal, text, stored_projection_json)
          end

          # Call only on already-verified text; this would bless an unverified edit.
          def backfill_frozen_facts!(ordinal, text, stored_projection_json)
            archive_text!(ordinal, text)
            return if stored_projection_json

            projection = Runtime::EraTamper.project(text)
            return unless projection

            @db.exec_params(
              "UPDATE hecks_eras SET held_projection = $3::text::jsonb " \
              "WHERE domain = $1 AND ordinal = $2 AND held_projection IS NULL",
              [@domain, ordinal, JSON.generate(projection)]
            )
          end

          private

          def record_attestation!(ordinal, old_digest, new_digest)
            @db.exec_params(
              "INSERT INTO hecks_attestations (domain, ordinal, old_digest, new_digest) VALUES ($1, $2, $3, $4)",
              [@domain, ordinal, old_digest, new_digest]
            )
          end

          def adopt_digest!(ordinal, digest)
            @db.exec_params(
              "UPDATE hecks_eras SET held_digest = $3 WHERE domain = $1 AND ordinal = $2",
              [@domain, ordinal, digest]
            )
          end

          def store_missing_digest!(ordinal, digest)
            @db.exec_params(
              "UPDATE hecks_eras SET held_digest = $3 WHERE domain = $1 AND ordinal = $2 AND held_digest IS NULL",
              [@domain, ordinal, digest]
            )
          end
        end
      end
    end
  end
end
