module Hecksagain
  module Adapters
    class Postgres
      class Lineage
        module EraStore
          # Every held text is verified against its raw-byte digest on the
          # way out — an edited storage fact refuses rather than silently
          # reporting "no drift". This is NOT the era name (which hashes
          # the canonical projection, minted once, never recomputed): it
          # is a plain integrity check over bytes, and a row from before
          # the check existed is backfilled, not refused.
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

          # The unverified row — what bin/reattest_era shows an operator
          # after the integrity check fires.
          def raw_era(ordinal)
            rows = @db.exec_params(
              "SELECT held_text, held_digest, hash, held_projection::text FROM hecks_eras WHERE domain = $1 AND ordinal = $2",
              [@domain, ordinal]
            )
            return nil if rows.ntuples.zero?

            { held_text: rows[0]["held_text"], held_digest: rows[0]["held_digest"], hash: rows[0]["hash"],
              held_projection: rows[0]["held_projection"] }
          end

          # The recovery path: tamper-EVIDENCE (against accident and
          # drift, not adversaries) gets resolved by a human acknowledging
          # the text as it now stands — recorded in an append-only
          # attestation table, never by a bare psql UPDATE.
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

            raise Runtime::WiringError, Ports::Persistence::EraTamper.refusal(
              domain: @domain, ordinal: ordinal, edited_text: text,
              stored_projection: stored_projection_json && JSON.parse(stored_projection_json)
            )
          end

          # A verified-authentic text backfills what older rows lack: its
          # projection and its archive copy. Never run on a text that
          # failed verification — that would bless the edit.
          def backfill_frozen_facts!(ordinal, text, stored_projection_json)
            archive_text!(ordinal, text)
            return if stored_projection_json

            projection = Ports::Persistence::EraTamper.project(text)
            return unless projection

            @db.exec_params(
              "UPDATE hecks_eras SET held_projection = $3::text::jsonb " \
              "WHERE domain = $1 AND ordinal = $2 AND held_projection IS NULL",
              [@domain, ordinal, JSON.generate(projection)]
            )
          end

          def current_era
            held = eras
            held.empty? ? 1 : held.last[:ordinal]
          end

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

          def archive_text!(ordinal, text)
            @db.exec_params(
              "INSERT INTO hecks_era_texts (domain, ordinal, digest, held_text) VALUES ($1, $2, $3, $4) " \
              "ON CONFLICT DO NOTHING",
              [@domain, ordinal, Digest::SHA256.hexdigest(text), text]
            )
          end

          # A Layer-3 approval, recorded IN the database it was reviewed
          # against — bound to the edge's parsed content and the journal's
          # high-water ordinal at review time. The latest row for a shape
          # pair wins (re-approval supersedes).
          def record_approval!(from:, to:, edge_digest:)
            @db.exec_params(
              "INSERT INTO hecks_approvals (domain, from_label, to_label, edge_digest, reviewed_ordinal) " \
              "VALUES ($1, $2, $3, $4, $5)",
              [@domain, from, to, edge_digest, last_ordinal]
            )
          end

          def approval_for(from:, to:)
            rows = @db.exec_params(
              "SELECT edge_digest, reviewed_ordinal FROM hecks_approvals " \
              "WHERE domain = $1 AND from_label = $2 AND to_label = $3 ORDER BY approved_at DESC, reviewed_ordinal DESC LIMIT 1",
              [@domain, from, to]
            )
            return nil if rows.ntuples.zero?

            { edge_digest: rows[0]["edge_digest"], reviewed_ordinal: rows[0]["reviewed_ordinal"].to_i }
          end

          # Era identity is minted ONCE and stored; nothing ever recomputes
          # a stored name to verify it.
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
