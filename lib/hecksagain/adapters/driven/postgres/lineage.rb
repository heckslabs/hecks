require "json"
require "digest"

module Hecksagain
  module Adapters
    class Postgres
      # The lineage topology inside one Postgres database: one journal
      # per domain, LIST-partitioned by era, with a single ordinal
      # sequence spanning partitions (total order across eras is
      # structural); a `hecks_eras` table holding each era's frozen
      # source text, its once-minted hash/label, and the watermark cut
      # into its ancestor; and, per aggregate, a HEAD derived from the
      # journal — never a table anything rewrites.
      #
      # For era 1 the head is a plain view (latest save per id). From
      # era 2 on, the ancestor tail is a MATERIALIZED view whose
      # definition is the compiled, chained edge sequence — one CTE per
      # original edge, in mint order, never a flattened merged rule set
      # — with the watermark baked into the definition, so post-cut
      # old-era writes cannot leak into the new head even on REFRESH.
      # Live current-era writes overlay it through the head view.
      #
      # Lineage order is ordinal-assignment order: the ordinal comes
      # from a sequence, sequences are non-transactional, and that is
      # accepted and documented rather than papered over.
      class Lineage
        JOURNAL_COLUMNS = "ordinal, era, aggregate, aggregate_id, operation, state, mirrors".freeze

        attr_reader :db, :domain

        def initialize(db, domain)
          @db = db
          @domain = domain.to_s
        end

        def journal = "hecks_journal_#{Naming.snake(@domain)}"
        def quoted_journal = quote(journal)
        def sequence = "#{journal}_ordinal"
        def partition(era) = "#{journal}_era_#{era}"
        def head_view(storage_name) = "#{storage_name}_head"
        def matview(storage_name, era, label) = "#{storage_name}_lineage_#{era}_#{label}"

        def ensure_base!
          @db.exec(<<~SQL)
            CREATE TABLE IF NOT EXISTS hecks_eras (
              domain    text NOT NULL,
              ordinal   int  NOT NULL,
              hash      text,
              label     text,
              held_text text NOT NULL,
              watermark bigint,
              PRIMARY KEY (domain, ordinal)
            )
          SQL
          @db.exec("ALTER TABLE hecks_eras ADD COLUMN IF NOT EXISTS held_digest text")
          @db.exec("ALTER TABLE hecks_eras ADD COLUMN IF NOT EXISTS held_projection jsonb")
          # which canonical-form version minted this name — see
          # Runtime::StorageShape::FORM_VERSION; rows minted before the
          # column carry NULL, read as an implicit 1
          @db.exec("ALTER TABLE hecks_eras ADD COLUMN IF NOT EXISTS canon_form int")
          # every frozen text version, archived where an edit cannot
          # reach it — the recovery the hard reattest refusal points at
          @db.exec(<<~SQL)
            CREATE TABLE IF NOT EXISTS hecks_era_texts (
              domain      text NOT NULL,
              ordinal     int  NOT NULL,
              digest      text NOT NULL,
              held_text   text NOT NULL,
              archived_at timestamptz NOT NULL DEFAULT now(),
              PRIMARY KEY (domain, ordinal, digest)
            )
          SQL
          @db.exec(<<~SQL)
            CREATE TABLE IF NOT EXISTS hecks_approvals (
              domain           text NOT NULL,
              from_label       text NOT NULL,
              to_label         text NOT NULL,
              edge_digest      text NOT NULL,
              reviewed_ordinal bigint NOT NULL,
              approved_at      timestamptz NOT NULL DEFAULT now()
            )
          SQL
          @db.exec("CREATE SEQUENCE IF NOT EXISTS #{quote(sequence)}")
          # GENERATED ALWAYS AS IDENTITY is the intent, but identity
          # columns on partitioned tables need Postgres 17 — an owned
          # sequence default is the same spanning ordinal on any
          # supported server.
          @db.exec(<<~SQL)
            CREATE TABLE IF NOT EXISTS #{quoted_journal} (
              ordinal      bigint NOT NULL DEFAULT nextval('#{sequence}'),
              era          int    NOT NULL,
              aggregate    text   NOT NULL,
              aggregate_id text   NOT NULL,
              operation    text   NOT NULL DEFAULT 'save',
              state        jsonb,
              mirrors      jsonb
            ) PARTITION BY LIST (era)
          SQL
          ensure_partition!(1)
          # Immutability by privilege: nothing updates or deletes journal
          # rows. The owner's implicit rights remain (Postgres has no way
          # to revoke them from the owner itself); a deployment's app
          # role connects as a NON-owner and gets exactly INSERT, per
          # era, at mint time.
          @db.exec("REVOKE UPDATE, DELETE ON #{quoted_journal} FROM PUBLIC")
          install_transforms!
        end

        def ensure_partition!(era)
          @db.exec(<<~SQL)
            CREATE TABLE IF NOT EXISTS #{quote(partition(era))}
              PARTITION OF #{quoted_journal} FOR VALUES IN (#{era.to_i})
          SQL
        end

        # ── eras ────────────────────────────────────────────────────────

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

        # ── the mint transaction ───────────────────────────────────────
        #
        # One transaction: the new era row (held text + minted name +
        # cut watermark), the new partition, and every aggregate's
        # recompiled matview + head view. The advisory lock is the
        # writer fence — two concurrent minters serialize, and the
        # second finds the era already held. Populating the matview
        # inside the transaction means a convert meeting an unmapped
        # value REFUSES the whole mint, loudly, before anything boots.
        def mint_era!(ordinal:, hash:, label:, held_text:, aggregates:, edges:, role: nil, projection: nil)
          @db.exec("BEGIN")
          # A concurrent minter blocks briefly, then refuses with a name
          # rather than hanging: mint is non-interactive (the human
          # decision already happened in the audit tool), so the lock is
          # only ever held for the transaction itself.
          @db.exec("SET LOCAL lock_timeout = '10s'")
          @db.exec("SELECT pg_advisory_xact_lock(hashtext('hecks_eras:' || #{text_literal(@domain)}))")
          if eras.any? { |era| era[:ordinal] == ordinal }
            @db.exec("ROLLBACK")
            return false
          end

          watermark = last_ordinal
          @db.exec_params(
            "INSERT INTO hecks_eras (domain, ordinal, hash, label, held_text, watermark, held_digest, held_projection, canon_form) " \
            "VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)",
            [@domain, ordinal, hash, label, held_text, watermark, Digest::SHA256.hexdigest(held_text),
             projection && JSON.generate(projection), Runtime::StorageShape::FORM_VERSION]
          )
          archive_text!(ordinal, held_text)
          ensure_partition!(ordinal)
          grant_era!(ordinal, role) if role
          aggregates.each { |aggregate| compile_head!(aggregate, ordinal, label, edges) }
          @db.exec("COMMIT")
          true
        rescue PG::LockNotAvailable
          @db.exec("ROLLBACK") rescue nil
          raise Runtime::WiringError,
                "cannot mint era #{ordinal} of #{@domain}: another mint holds the domain lock — " \
                "waited 10s; try again shortly"
        rescue PG::Error => error
          @db.exec("ROLLBACK") rescue nil
          raise Runtime::WiringError, "cannot mint era #{ordinal} of #{@domain}: #{error.message.strip}"
        end

        # Per-era INSERT grants: the app role (a NON-owner) may append
        # into exactly one partition — the era its checkout speaks. An
        # OLD checkout keeps its own role's grant on its own partition
        # (the fork, Phase 5); this connection's role moves forward.
        def grant_era!(ordinal, role)
          quoted_role = quote(role)
          @db.exec("REVOKE INSERT ON #{quote(partition(ordinal - 1))} FROM #{quoted_role}") if ordinal > 1
          @db.exec("GRANT INSERT ON #{quote(partition(ordinal))} TO #{quoted_role}")
          @db.exec("GRANT SELECT ON #{quoted_journal} TO #{quoted_role}")
          @db.exec("GRANT USAGE ON SEQUENCE #{quote(sequence)} TO #{quoted_role}")
        end

        # ── fork observability ─────────────────────────────────────────

        # Post-cut writes an old era made after the newer era was minted
        # — the divergence between the worlds, observable at any time.
        def diverged_count(old_era)
          cut = eras.find { |era| era[:ordinal] == old_era + 1 }&.dig(:watermark)
          return 0 unless cut

          @db.exec(
            "SELECT count(*) FROM #{quoted_journal} WHERE era = #{old_era.to_i} AND ordinal > #{cut.to_i}"
          )[0]["count"].to_i
        end

        # ── tail-merge ─────────────────────────────────────────────────
        #
        # The one deliberate command — it marks a business event (an app
        # retiring), never a shape change. One transaction: advance the
        # watermarks, rebuild the head so the tail interleaves by its
        # recorded global ordinal, append the declared winners, audit —
        # and roll the whole thing back on any refusal. Records touched
        # by both worlds since the cut refuse until each has an explicit
        # winner; resolution itself is append-only (the winner's state
        # re-enters as the newest row and wins structurally — originals
        # stay immutable).
        def merge_tail!(aggregates:, edges:, winners: {}, audit: nil)
          @db.exec("BEGIN")
          @db.exec("SET LOCAL lock_timeout = '10s'")
          @db.exec("SELECT pg_advisory_xact_lock(hashtext('hecks_eras:' || #{text_literal(@domain)}))")
          held = eras
          era = held.last[:ordinal]
          label = held.last[:label]
          if era == 1
            @db.exec("ROLLBACK")
            raise Runtime::WiringError, "nothing to merge — #{@domain} stands at era 1"
          end
          cut = held.last[:watermark].to_i
          tip = last_ordinal

          conflicts = aggregates.flat_map { |aggregate| conflict_ids(aggregate, edges, era, cut) }
          unresolved = conflicts.reject { |_, id| winners.key?(id) }
          unless unresolved.empty?
            @db.exec("ROLLBACK")
            raise Runtime::WiringError,
                  "cannot merge the tail of #{@domain}: touched by both worlds since the cut — " \
                  "#{unresolved.map { |storage, id| "#{storage}##{id}" }.sort.join(', ')}. " \
                  "Name each winner (--winner <id>=old or --winner <id>=new), then run bin/merge_tail again. " \
                  "A winner takes the WHOLE record — the aggregate is the consistency boundary, so the " \
                  "loser's edits are discarded even where they touched different attributes"
          end

          # the new world's pre-merge head states, captured before the
          # rebuild lets the tail interleave
          new_states = {}
          aggregates.each do |aggregate|
            winners.select { |_, side| side == "new" }.each_key do |id|
              row = @db.exec_params("SELECT state FROM #{quote(head_view(aggregate.storage_name))} WHERE id = $1", [id])
              new_states[id] = [aggregate.storage_name, row[0]["state"]] if row.ntuples.positive?
            end
          end

          @db.exec_params("UPDATE hecks_eras SET watermark = $2 WHERE domain = $1 AND ordinal > 1", [@domain, tip])
          aggregates.each do |aggregate|
            @db.exec("DROP VIEW IF EXISTS #{quote(head_view(aggregate.storage_name))}")
            @db.exec("DROP MATERIALIZED VIEW IF EXISTS #{quote(matview(aggregate.storage_name, era, label))}")
            compile_head!(aggregate, era, label, edges)
          end

          winners.each do |id, side|
            aggregates.each do |aggregate|
              state =
                if side == "old"
                  row = @db.exec_params(
                    "SELECT state FROM #{quote(matview(aggregate.storage_name, era, label))} " \
                    "WHERE aggregate_id = $1 AND operation = 'save' ORDER BY ordinal DESC LIMIT 1",
                    [id]
                  )
                  row.ntuples.positive? ? row[0]["state"] : nil
                else
                  new_states[id]&.first == aggregate.storage_name ? new_states[id][1] : nil
                end
              next unless state

              @db.exec_params(
                "INSERT INTO #{quoted_journal} (era, aggregate, aggregate_id, operation, state) " \
                "VALUES ($1, $2, $3, 'save', $4)",
                [era, aggregate.storage_name, id, state]
              )
            end
          end

          if audit
            violations = audit.call
            unless violations.empty?
              @db.exec("ROLLBACK")
              raise Runtime::WiringError,
                    "cannot merge the tail of #{@domain}: the audit refused —\n  - #{violations.join("\n  - ")}"
            end
          end

          @db.exec("COMMIT")
          true
        rescue PG::LockNotAvailable
          @db.exec("ROLLBACK") rescue nil
          raise Runtime::WiringError,
                "cannot merge the tail of #{@domain}: another mint or merge holds the domain lock — " \
                "waited 10s; try again shortly"
        rescue PG::Error => error
          @db.exec("ROLLBACK") rescue nil
          raise Runtime::WiringError, "cannot merge the tail of #{@domain}: #{error.message.strip}"
        end

        # Ids touched by BOTH worlds since the cut — the old world's
        # post-cut tail INTERSECTed with the new world's own writes.
        def conflict_ids(aggregate, edges, era, cut)
          names = names_by_era(aggregate, edges)
          olds = (1...era).map { |ancestor| text_literal(names[:storage][ancestor - 1]) }.join(", ")
          @db.exec(<<~SQL).map { |row| [aggregate.storage_name, row["aggregate_id"]] }
            SELECT aggregate_id FROM #{quoted_journal}
            WHERE era < #{era.to_i} AND aggregate IN (#{olds}) AND ordinal > #{cut.to_i}
            INTERSECT
            SELECT aggregate_id FROM #{quoted_journal}
            WHERE era = #{era.to_i} AND aggregate = #{text_literal(names[:storage][era - 1])}
          SQL
        end

        # ── head compilation ───────────────────────────────────────────

        # Era 1: the head is simply the latest save per id.
        def ensure_first_head!(storage_name)
          return if view_exists?(head_view(storage_name))

          @db.exec(<<~SQL)
            CREATE OR REPLACE VIEW #{quote(head_view(storage_name))} AS
            SELECT id, state FROM (
              SELECT DISTINCT ON (aggregate_id) aggregate_id AS id, operation, state
              FROM #{quoted_journal}
              WHERE aggregate = #{text_literal(storage_name)}
              ORDER BY aggregate_id, ordinal DESC
            ) latest WHERE operation = 'save'
          SQL
        end

        # The compiled chain over the ancestor tail — the matview's body,
        # also runnable as a LIVE query (the audit previews a pending
        # era through exactly this SQL before anything is minted).
        #
        # NEVER flatten the edges into one merged rule set, however
        # tempting the optimization looks. The two-line counterexample:
        # edge 1 renames A→B, edge 2 renames C→A. Flattened, a single
        # phase order either applies C→A before A→B (aliasing C's value
        # into B) or drops the recycled name entirely — there is NO
        # correct position for both rules in one pass. Chaining the
        # original edges in mint order reproduces the true execution
        # exactly and needs no such reasoning.
        def chain_sql(aggregate, era, edges)
          names = names_by_era(aggregate, edges)
          tail = ancestor_tail_sql(names, era)
          chain = edges.each_with_index.map do |edge, index|
            declared = edge[:translation].for_aggregate(names[:current][index + 1])
            expression = declared ? compile_rules(declared) : "state"
            "edge_#{index + 1} AS (SELECT ordinal, era, aggregate_id, operation, " \
              "CASE WHEN era <= #{index + 1} AND operation = 'save' THEN #{expression} ELSE state END AS state " \
              "FROM #{index.zero? ? 'tail' : "edge_#{index}"})"
          end

          <<~SQL
            WITH tail AS (#{tail}),
            #{chain.join(",\n")}
            SELECT ordinal, aggregate_id, operation, state FROM edge_#{edges.size}
          SQL
        end

        # The translated tail as it would stand in era `era`, latest
        # entry per id, saves only — what the audit holds up against the
        # bluebook and the edge.
        def translated_latest(aggregate, era, edges)
          latest_of(chain_sql(aggregate, era, edges))
        end

        # The UNtranslated ancestor tail, latest entry per id — the
        # "before" side of every per-rule preservation check.
        def ancestor_latest(aggregate, era, edges)
          names = names_by_era(aggregate, edges)
          tail = ancestor_tail_sql(names, era)
          return {} if tail.empty?

          latest_of("SELECT ordinal, era, aggregate_id, operation, state FROM (#{tail}) tail_rows")
        end

        def latest_of(sql)
          rows = @db.exec(<<~SQL)
            SELECT aggregate_id, state FROM (
              SELECT DISTINCT ON (aggregate_id) aggregate_id, operation, state
              FROM (#{sql}) chained ORDER BY aggregate_id, ordinal DESC
            ) latest WHERE operation = 'save'
          SQL
          rows.to_h { |row| [row["aggregate_id"], JSON.parse(row["state"])] }
        end

        # Era N: materialize the translated ancestor tail (edge chain as
        # CTEs, watermarks baked in), then overlay live current-era rows
        # in a plain view.
        #
        # THE FROZEN-TAIL INVARIANT. This materialized view is correct
        # by construction only because BOTH of these hold:
        #   1. journal rows are never updated or deleted (immutability
        #      by privilege), and
        #   2. the watermark is baked into this definition as a LITERAL,
        #      so post-cut ancestor writes — which DO keep arriving
        #      while a fork is live — can never enter the head, even on
        #      a full REFRESH.
        # The ancestor partition is append-only but NOT frozen. Any
        # future "optimization" that refreshes incrementally, reads the
        # watermark from hecks_eras at query time, or otherwise
        # re-derives the cut will silently leak the old world's post-cut
        # writes into the new head. Rebuilding the definition (mint,
        # merge) is the only way the cut may move.
        def compile_head!(aggregate, era, label, edges)
          storage_name = aggregate.storage_name
          view = matview(storage_name, era, label)
          @db.exec(<<~SQL)
            CREATE MATERIALIZED VIEW #{quote(view)} AS
            #{chain_sql(aggregate, era, edges)}
          SQL

          @db.exec("DROP VIEW IF EXISTS #{quote(head_view(storage_name))}")
          @db.exec(<<~SQL)
            CREATE VIEW #{quote(head_view(storage_name))} AS
            SELECT id, state FROM (
              SELECT DISTINCT ON (aggregate_id) aggregate_id AS id, operation, state FROM (
                SELECT ordinal, aggregate_id, operation, state FROM #{quote(view)}
                UNION ALL
                SELECT ordinal, aggregate_id, operation, state FROM #{quoted_journal}
                WHERE era = #{era.to_i} AND aggregate = #{text_literal(storage_name)}
              ) merged ORDER BY aggregate_id, ordinal DESC
            ) latest WHERE operation = 'save'
          SQL
        end

        # The aggregate's storage name AS OF each era: `was:` chains
        # walked backward from the current name, one edge at a time.
        # names[:current][i] is the declared (Pascal) name after edge i;
        # names[:storage][e] the snake storage name DURING era e (1-based).
        def names_by_era(aggregate, edges)
          current = Array.new(edges.size + 1)
          current[edges.size] = aggregate.name
          (edges.size - 1).downto(0) do |index|
            declared = edges[index][:translation].for_aggregate(current[index + 1])
            current[index] = declared&.was || current[index + 1]
          end
          storage = current.map { |name| Naming.snake(name) }
          { current: current, storage: storage }
        end

        # Rows this aggregate contributed to every ancestor era, under
        # the name it had THEN, cut at the watermark recorded when the
        # next era was minted.
        def ancestor_tail_sql(names, era)
          watermarks = eras.to_h { |held| [held[:ordinal], held[:watermark]] }
          selects = (1...era).map do |ancestor|
            cut = watermarks[ancestor + 1]
            "SELECT ordinal, era, aggregate, aggregate_id, operation, state FROM #{quoted_journal} " \
              "WHERE era = #{ancestor} AND aggregate = #{text_literal(names[:storage][ancestor - 1])}" \
              "#{cut ? " AND ordinal <= #{cut}" : ''}"
          end
          selects.join(" UNION ALL ")
        end

        # One edge's rules over one jsonb state, compiled as a nested
        # expression tree — hecks_tr_* helpers composed innermost-first
        # in the reference transform's phase order (renames, moves,
        # converts, drops), computes last. `retype` compiles to nothing:
        # stored state never carries a type name.
        def compile_rules(declared)
          expression = "state"
          declared.renames.each do |old_name, new_name|
            expression = "hecks_tr_rename(#{expression}, #{text_literal(old_name)}, #{text_literal(new_name)})"
          end
          declared.moves.each do |move|
            expression = "hecks_tr_move(#{expression}, #{path_literal(move.from)}, #{path_literal(move.to)})"
          end
          declared.converts.each do |convert|
            pairs = JSON.generate(convert.values.map { |key, value| [key, value] })
            expression = "hecks_tr_convert(#{expression}, #{path_literal(convert.from)}, #{path_literal(convert.to)}, " \
                         "#{text_literal(pairs)}::jsonb, #{text_literal(convert.from)})"
          end
          declared.drops.each do |name|
            expression = "hecks_tr_drop(#{expression}, #{path_literal(name)})"
          end
          declared.computes.each do |compute|
            expression = compile_compute(expression, compute)
          end
          expression
        end

        # A compute is the one rule whose SQL is its only implementation
        # — evaluated exclusively here, inside the compiled head, never
        # in-process. The old field is exposed under its own name (as
        # text, exactly as the author's expression expects to cast it).
        def compile_compute(expression, compute)
          from = compute.from.to_s
          to = compute.to.to_s
          "(SELECT CASE WHEN __s ? #{text_literal(from)} THEN " \
            "hecks_tr_insert(__s - #{text_literal(from)}, #{path_literal(to)}, to_jsonb((#{compute.sql}))) " \
            "ELSE __s END " \
            "FROM (SELECT (#{expression}) AS __s) __outer, " \
            "LATERAL (SELECT (__s ->> #{text_literal(from)}) AS #{quote(from)}) __fields)"
        end

        def view_exists?(name)
          @db.exec_params(
            "SELECT 1 FROM information_schema.views WHERE table_name = $1 " \
            "UNION SELECT 1 FROM pg_matviews WHERE matviewname = $1",
            [name]
          ).ntuples.positive?
        end

        # The jsonb rule transforms — installed once, idempotently. Kept
        # equal to the port's reference entry-JSON transform by the
        # cross-execution equivalence spec; the SQL here is a compilation
        # target, not a second source of truth.
        def install_transforms!
          @db.exec(<<~SQL)
            CREATE OR REPLACE FUNCTION hecks_tr_extract(state jsonb, path text[], OUT remaining jsonb, OUT value jsonb, OUT present boolean)
            LANGUAGE plpgsql IMMUTABLE AS $fn$
            DECLARE parent jsonb; leaf text;
            BEGIN
              remaining := state;
              present := false;
              leaf := path[array_upper(path, 1)];
              IF array_length(path, 1) = 1 THEN
                IF state ? leaf THEN
                  present := true;
                  value := state -> leaf;
                  remaining := state - leaf;
                END IF;
                RETURN;
              END IF;
              parent := state #> path[1:array_upper(path, 1) - 1];
              IF jsonb_typeof(parent) = 'object' AND parent ? leaf THEN
                present := true;
                value := parent -> leaf;
                parent := parent - leaf;
                IF parent = '{}'::jsonb THEN
                  remaining := state - path[1];
                ELSE
                  remaining := jsonb_set(state, path[1:array_upper(path, 1) - 1], parent);
                END IF;
              END IF;
            END $fn$
          SQL
          @db.exec(<<~SQL)
            CREATE OR REPLACE FUNCTION hecks_tr_insert(state jsonb, path text[], value jsonb) RETURNS jsonb
            LANGUAGE plpgsql IMMUTABLE AS $fn$
            BEGIN
              IF array_length(path, 1) = 1 THEN
                RETURN state || jsonb_build_object(path[1], value);
              END IF;
              IF state -> path[1] IS NULL OR jsonb_typeof(state -> path[1]) <> 'object' THEN
                state := state || jsonb_build_object(path[1], '{}'::jsonb);
              END IF;
              RETURN jsonb_set(state, path, value);
            END $fn$
          SQL
          @db.exec(<<~SQL)
            CREATE OR REPLACE FUNCTION hecks_tr_rename(state jsonb, old_name text, new_name text) RETURNS jsonb
            LANGUAGE sql IMMUTABLE AS $fn$
              SELECT CASE WHEN state ? old_name
                THEN (state - old_name) || jsonb_build_object(new_name, state -> old_name)
                ELSE state END
            $fn$
          SQL
          @db.exec(<<~SQL)
            CREATE OR REPLACE FUNCTION hecks_tr_move(state jsonb, from_path text[], to_path text[]) RETURNS jsonb
            LANGUAGE plpgsql IMMUTABLE AS $fn$
            DECLARE extracted record;
            BEGIN
              SELECT * INTO extracted FROM hecks_tr_extract(state, from_path);
              IF NOT extracted.present THEN RETURN state; END IF;
              RETURN hecks_tr_insert(extracted.remaining, to_path, extracted.value);
            END $fn$
          SQL
          @db.exec(<<~SQL)
            CREATE OR REPLACE FUNCTION hecks_tr_convert(state jsonb, from_path text[], to_path text[], pairs jsonb, from_label text) RETURNS jsonb
            LANGUAGE plpgsql IMMUTABLE AS $fn$
            DECLARE extracted record; pair jsonb;
            BEGIN
              SELECT * INTO extracted FROM hecks_tr_extract(state, from_path);
              IF NOT extracted.present THEN RETURN state; END IF;
              FOR pair IN SELECT * FROM jsonb_array_elements(pairs) LOOP
                IF pair -> 0 = extracted.value THEN
                  RETURN hecks_tr_insert(extracted.remaining, to_path, pair -> 1);
                END IF;
              END LOOP;
              RAISE EXCEPTION 'cannot translate %: % has no mapping in its convert''s values: table. Add % => ... to cover it.',
                from_label, extracted.value, extracted.value;
            END $fn$
          SQL
          @db.exec(<<~SQL)
            CREATE OR REPLACE FUNCTION hecks_tr_drop(state jsonb, path text[]) RETURNS jsonb
            LANGUAGE plpgsql IMMUTABLE AS $fn$
            DECLARE extracted record;
            BEGIN
              SELECT * INTO extracted FROM hecks_tr_extract(state, path);
              RETURN extracted.remaining;
            END $fn$
          SQL
        end

        private

        def quote(name) = PG::Connection.quote_ident(name.to_s)

        def text_literal(text) = "'#{text.to_s.gsub("'", "''")}'"

        def path_literal(path)
          segments = path.to_s.split(".").map { |segment| text_literal(segment) }
          "ARRAY[#{segments.join(', ')}]::text[]"
        end
      end
    end
  end
end
