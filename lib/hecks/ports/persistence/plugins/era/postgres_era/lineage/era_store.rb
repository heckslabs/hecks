require_relative "../../era_tamper"
require_relative "../../../../../../runtime/registry"
require_relative "../../storage_shape"

module Hecks
  module Adapters
    class PostgresEra
      class Lineage
        # CRUD over `hecks_eras`/`hecks_era_texts`/`hecks_approvals`: reading
        # and tamper-verifying held era text, archiving every frozen text
        # version, recording a Layer-3 approval, and minting an era's name
        # once (never recomputed after).
        module EraStore
          # Lists every era the domain holds, oldest first, refusing any whose text was edited.
          #
          # Every held text is verified against its raw-byte digest on the
          # way out — an edited storage fact refuses rather than silently
          # reporting "no drift". This is not the era name (which hashes
          # the canonical projection, minted once, never recomputed): it
          # is a plain integrity check over bytes, and a row that carries
          # no digest yet is backfilled, not refused.
          #
          # @return [Array<Hash{Symbol => Object}>] one Hash per era in ordinal order, `[]` when
          #   the domain holds none; keys are `:ordinal` (Integer), `:hash` and `:label` (String,
          #   nil until `mint_name!` names the era), `:held_text` (String) and `:watermark`
          #   (Integer journal ordinal the era was cut at, nil for era 1)
          # @raise [Runtime::WiringError] if a held text no longer matches its stored digest
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

          # Reads one era's stored row without running the integrity check that `eras` applies.
          #
          # The unverified row — what bin/reattest_era shows an operator
          # after the integrity check fires.
          #
          # @param ordinal [Integer] ordinal of the era to read
          # @return [Hash{Symbol => String, nil}, nil] `:held_text`, `:held_digest` (SHA-256 hex,
          #   nil if never stored), `:hash` (nil until minted) and `:held_projection` (JSON text,
          #   nil if never stored); nil when the domain holds no such era
          def raw_era(ordinal)
            rows = @db.exec_params(
              "SELECT held_text, held_digest, hash, held_projection::text FROM hecks_eras WHERE domain = $1 AND ordinal = $2",
              [@domain, ordinal]
            )
            return nil if rows.ntuples.zero?

            { held_text: rows[0]["held_text"], held_digest: rows[0]["held_digest"], hash: rows[0]["hash"],
              held_projection: rows[0]["held_projection"] }
          end

          # Accepts an era's held text as it now stands, replacing its stored digest.
          #
          # The recovery path: tamper-evidence (against accident and
          # drift, not adversaries) gets resolved by a human acknowledging
          # the text as it now stands — recorded in an append-only
          # attestation table, never by a bare psql `UPDATE`.
          #
          # @param ordinal [Integer] ordinal of the era to re-attest
          # @return [String] the new SHA-256 hex digest of the held text
          # @raise [Runtime::WiringError] if the domain holds no era with that ordinal
          # @raise [PG::Error] if Postgres refuses the attestation DDL or a write
          def reattest!(ordinal)
            era = raw_era(ordinal)
            raise Runtime::WiringError, "#{@domain} holds no era #{ordinal} to re-attest" unless era

            fresh = Digest::SHA256.hexdigest(era[:held_text])
            @db.exec(<<~SQL)
              CREATE TABLE IF NOT EXISTS hecks_attestations (
                domain      text NOT NULL,
                ordinal     int  NOT NULL,
                old_digest  text,
                new_digest  text NOT NULL,
                attested_at timestamptz NOT NULL DEFAULT now()
              )
            SQL
            @db.exec_params(
              "INSERT INTO hecks_attestations (domain, ordinal, old_digest, new_digest) VALUES ($1, $2, $3, $4)",
              [@domain, ordinal, era[:held_digest], fresh]
            )
            @db.exec_params(
              "UPDATE hecks_eras SET held_digest = $3 WHERE domain = $1 AND ordinal = $2",
              [@domain, ordinal, fresh]
            )
            archive_text!(ordinal, era[:held_text])
            fresh
          end

          # Checks one held text against its stored digest, storing the digest if the row has none.
          #
          # A text that passes (or that had no digest to fail against) also gets
          # `backfill_frozen_facts!`; a text that fails gets nothing written.
          #
          # @param ordinal [Integer] ordinal of the era the text belongs to
          # @param text [String] the era's held bluebook source text
          # @param stored_digest [String, nil] SHA-256 hex digest stored with the row; nil when
          #   the row carries none yet
          # @param stored_projection_json [String, nil] the row's stored projection as JSON text;
          #   nil when the row carries none yet
          # @return [void]
          # @raise [Runtime::WiringError] if `stored_digest` is present and does not match `text`
          def verify_integrity!(ordinal, text, stored_digest, stored_projection_json)
            digest = Digest::SHA256.hexdigest(text)
            if stored_digest.nil?
              @db.exec_params(
                "UPDATE hecks_eras SET held_digest = $3 WHERE domain = $1 AND ordinal = $2 AND held_digest IS NULL",
                [@domain, ordinal, digest]
              )
              backfill_frozen_facts!(ordinal, text, stored_projection_json)
              return
            end
            if stored_digest == digest
              backfill_frozen_facts!(ordinal, text, stored_projection_json)
              return
            end

            raise Runtime::WiringError, Runtime::EraTamper.refusal(domain: @domain, ordinal: ordinal)
          end

          # Fills in the archive copy and the stored projection an era row is missing.
          #
          # A verified-authentic text backfills what a row may lack: its
          # projection and its archive copy. Never run on a text that
          # failed verification — that would bless the edit.
          #
          # @param ordinal [Integer] ordinal of the era the text belongs to
          # @param text [String] the era's verified held source text
          # @param stored_projection_json [String, nil] the row's stored projection as JSON text;
          #   nil makes this derive one from `text` and store it, unless `text` does not load
          # @return [void]
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

          # Reports the ordinal of the newest era the domain holds.
          #
          # @return [Integer] the highest held ordinal, or 1 when no era is held yet
          # @raise [Runtime::WiringError] if a held text no longer matches its stored digest
          def current_era
            held = eras
            held.empty? ? 1 : held.last[:ordinal]
          end

          # Holds a domain's first source text as era 1 and makes era 1 the writable era.
          #
          # Call only while the domain holds no era — every caller checks `eras.empty?` first.
          # An existing era 1 row is kept (`ON CONFLICT DO NOTHING`), but `advance_era!(1)` runs
          # regardless, so calling this on a domain past era 1 would roll the write fence back.
          #
          # @param text [String] the bluebook source text to freeze as era 1
          # @param projection [Hash{String => Object}, nil] the storage-shape projection of the
          #   bluebook, as `Runtime::StorageShape.project` returns it; nil stores none
          # @return [void]
          # @raise [PG::Error] if Postgres refuses the insert or the policy change, as it does
          #   for a role that does not own the journal
          def hold_first!(text, projection: nil)
            @db.exec_params(
              "INSERT INTO hecks_eras (domain, ordinal, held_text, held_digest, held_projection) " \
              "VALUES ($1, 1, $2, $3, $4) ON CONFLICT DO NOTHING",
              [@domain, text, Digest::SHA256.hexdigest(text), projection && JSON.generate(projection)]
            )
            archive_text!(1, text)
            # Era 1 is the current era from its first moment — established
            # here, not left to whichever role happens to boot first.
            advance_era!(1)
          end

          # Copies one version of an era's text into `hecks_era_texts`, keyed by its digest.
          #
          # A version already archived is left alone (`ON CONFLICT DO NOTHING`), so every
          # distinct text an era ever held survives a re-attestation.
          #
          # @param ordinal [Integer] ordinal of the era the text belongs to
          # @param text [String] the source text to archive
          # @return [void]
          # @raise [PG::Error] if Postgres refuses the insert
          def archive_text!(ordinal, text)
            @db.exec_params(
              "INSERT INTO hecks_era_texts (domain, ordinal, digest, held_text) VALUES ($1, $2, $3, $4) " \
              "ON CONFLICT DO NOTHING",
              [@domain, ordinal, Digest::SHA256.hexdigest(text), text]
            )
          end

          # Records that a human approved a translation edge's audit samples.
          #
          # A Layer-3 approval, recorded in the database it was reviewed
          # against — bound to the edge's parsed content and the journal's
          # high-water ordinal at review time. The latest row for a shape
          # pair wins (re-approval supersedes).
          #
          # @param from [String] label of the era shape the edge leaves
          # @param to [String] label of the era shape the edge leads to
          # @param edge_digest [String] SHA-256 hex digest of the edge's parsed content, as
          #   `Translation::Audit.edge_digest` computes it
          # @return [void]
          # @raise [PG::Error] if Postgres refuses the insert
          def record_approval!(from:, to:, edge_digest:)
            @db.exec_params(
              "INSERT INTO hecks_approvals (domain, from_label, to_label, edge_digest, reviewed_ordinal) " \
              "VALUES ($1, $2, $3, $4, $5)",
              [@domain, from, to, edge_digest, last_ordinal]
            )
          end

          # Finds the most recent approval recorded for the edge between two era shapes.
          #
          # @param from [String] label of the era shape the edge leaves
          # @param to [String] label of the era shape the edge leads to
          # @return [Hash{Symbol => Object}, nil] `:edge_digest` (String, SHA-256 hex of the edge
          #   that was reviewed) and `:reviewed_ordinal` (Integer, the journal's highest ordinal at
          #   review time); nil when no approval is recorded for the pair
          def approval_for(from:, to:)
            rows = @db.exec_params(
              "SELECT edge_digest, reviewed_ordinal FROM hecks_approvals " \
              "WHERE domain = $1 AND from_label = $2 AND to_label = $3 ORDER BY approved_at DESC, reviewed_ordinal DESC LIMIT 1",
              [@domain, from, to]
            )
            return nil if rows.ntuples.zero?

            { edge_digest: rows[0]["edge_digest"], reviewed_ordinal: rows[0]["reviewed_ordinal"].to_i }
          end

          # Stores an era's hash and label, only if the era has no hash yet.
          #
          # Era identity is minted once and stored; nothing ever recomputes
          # a stored name to verify it.
          #
          # @param ordinal [Integer] ordinal of the era to name
          # @param hash [String] the era's shape hash, SHA-256 hex
          # @param label [String] the short label edges and refusals use, a prefix of `hash`
          # @return [void]
          # @raise [PG::Error] if Postgres refuses the update
          def mint_name!(ordinal, hash, label)
            @db.exec_params(
              "UPDATE hecks_eras SET hash = $3, label = $4, canon_form = $5 " \
              "WHERE domain = $1 AND ordinal = $2 AND hash IS NULL",
              [@domain, ordinal, hash, label, Runtime::StorageShape::FORM_VERSION]
            )
          end

          # Reads the journal's high-water mark across every era's partition.
          #
          # @return [Integer] the highest ordinal in the journal, or 0 when the journal is empty
          def last_ordinal
            @db.exec("SELECT COALESCE(max(ordinal), 0) AS o FROM #{quoted_journal}")[0]["o"].to_i
          end
        end
      end
    end
  end
end
