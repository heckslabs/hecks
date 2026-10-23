require_relative "../../era_tamper"
require_relative "../../../../../../runtime/registry"
require_relative "../../storage_shape"

module Hecks
  module Adapters
    class PostgresEra
      class Lineage
        # CRUD over `hecks_eras`/`hecks_era_texts`: era text
        # integrity, archiving, and once-only era naming.
        module EraStore
          # Verifies each held text's digest before returning it; a missing digest is backfilled.
          def eras
            @db.exec_params(
              "SELECT ordinal, hash, label, held_text, watermark, held_digest, held_projection::text " \
              "FROM hecks_eras WHERE domain = $1 ORDER BY ordinal",
              [@domain]
            ).map do |row|
              verify_integrity!(row["ordinal"].to_i, row["held_text"], row["held_digest"], row["held_projection"])
              { ordinal: row["ordinal"].to_i, hash: row["hash"], label: row["label"],
                held_text: row["held_text"], watermark: row["watermark"]&.to_i }
            end
          end

          def current_era
            held = eras
            held.empty? ? 1 : held.last[:ordinal]
          end

          # Call only while the domain holds no era; this always advances the write fence to era 1.
          def hold_first!(text, projection: nil)
            @db.exec_params(
              "INSERT INTO hecks_eras (domain, ordinal, held_text, held_digest, held_projection) " \
              "VALUES ($1, 1, $2, $3, $4) ON CONFLICT DO NOTHING",
              [@domain, text, Digest::SHA256.hexdigest(text), projection && JSON.generate(projection)]
            )
            archive_text!(1, text)
            # Set explicitly here, not left to whichever role happens to boot first.
            advance_era!(1)
          end

          # Left alone if already archived, so re-attestation never duplicates a text version.
          def archive_text!(ordinal, text)
            @db.exec_params(
              "INSERT INTO hecks_era_texts (domain, ordinal, digest, held_text) VALUES ($1, $2, $3, $4) " \
              "ON CONFLICT DO NOTHING",
              [@domain, ordinal, Digest::SHA256.hexdigest(text), text]
            )
          end

          # Sets hash/label only once; nothing ever recomputes a stored name to verify it.
          def mint_name!(ordinal, hash, label)
            @db.exec_params(
              "UPDATE hecks_eras SET hash = $3, label = $4, canon_form = $5 " \
              "WHERE domain = $1 AND ordinal = $2 AND hash IS NULL",
              [@domain, ordinal, hash, label, Runtime::StorageShape::FORM_VERSION]
            )
          end

          def last_ordinal
            @db.exec("SELECT COALESCE(max(ordinal), 0) AS o FROM #{quoted_journal}")[0]["o"].to_i
          end
        end
      end
    end
  end
end
