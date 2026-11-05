require_relative "../../../../ports/persistence/plugins/era/era_tamper"
require_relative "../../../../runtime/registry"
require_relative "../../../../ports/persistence/plugins/era/storage_shape"

module Hecks
  module Adapters
    class PostgresEra
      class Lineage
        # CRUD over `hecks_eras`/`hecks_era_texts`: era text
        # integrity, archiving, and once-only era naming.
        module RevisionStore
          # Verifies each held text's digest before returning it; a missing digest is backfilled. A
          # reading lineage verifies without writing.
          def eras
            return eras_unrecorded if @reading

            @db.exec_params(
              "SELECT ordinal, hash, label, held_text, watermark, held_digest, held_projection::text, edge::text " \
              "FROM hecks_eras WHERE domain = $1 ORDER BY ordinal",
              [@domain]
            ).map do |row|
              verify_integrity!(row["ordinal"].to_i, row["held_text"], row["held_digest"], row["held_projection"],
                                row["hash"])
              era_from(row)
            end
          end

          # The held eras as stored, each text checked against its digest in memory. Unlike `eras`,
          # nothing is archived or backfilled, so a reading works under a role that may only select.
          #
          # @return [Array<Hash>] the eras, as `eras` answers them
          # @raise [Runtime::WiringError] when a held text does not match its digest
          def eras_unrecorded
            return [] unless table_exists?("hecks_eras")

            @db.exec_params(
              "SELECT ordinal, hash, label, held_text, watermark, held_digest, held_projection::text, edge::text " \
              "FROM hecks_eras WHERE domain = $1 ORDER BY ordinal",
              [@domain]
            ).map { |row| unrecorded_era(row) }
          end

          def unrecorded_era(row)
            ordinal = row["ordinal"].to_i
            stored = row["held_digest"]
            if stored && stored != Digest::SHA256.hexdigest(row["held_text"])
              raise Runtime::WiringError, Runtime::RevisionTamper.refusal(domain: @domain, ordinal: ordinal)
            end

            era_from(row)
          end

          # @return [Hash] the era a row holds, as `eras` answers it
          def era_from(row)
            { ordinal: row["ordinal"].to_i, hash: row["hash"], label: row["label"], held_text: row["held_text"],
              watermark: row["watermark"]&.to_i, edge: parsed_edge(row["edge"]),
              projection: parsed_projection(row["held_projection"]) }
          end

          # @return [Hash, nil] the storage-shape projection the era's mint recorded, string-keyed
          #   as `StorageShape.project` answers it, or nil for an era minted without one
          def parsed_projection(text)
            text && JSON.parse(text)
          end

          # @return [Hash, nil] the edge column as symbol-keyed JSON, or nil for an era a written
          #   edge reached
          def parsed_edge(text)
            text && JSON.parse(text, symbolize_names: true)
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

          # How many journal rows above an ordinal belong to one record of one aggregate.
          #
          # @param ordinal [Integer] the ordinal the rows must exceed
          # @param aggregate [String] the aggregate's storage name
          # @param id [String] the record's id
          # @return [Integer]
          def rows_of_after(ordinal, aggregate, id)
            sql = "SELECT count(*) AS n FROM #{quoted_journal} WHERE ordinal > $1 AND aggregate = $2 AND aggregate_id = $3"
            @db.exec_params(sql, [ordinal, aggregate, id])[0]["n"].to_i
          end
        end
      end
    end
  end
end
