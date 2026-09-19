require "json"
require "digest"

require_relative "lineage/provisioning"
require_relative "lineage/era_store"
require_relative "lineage/mint_transaction"
require_relative "lineage/tail_merge"
require_relative "lineage/resumable_backfill"
require_relative "lineage/head_compiler"
require_relative "lineage/field_cache"
require_relative "lineage/transform_installer"
require_relative "../../../../../naming"

module Hecks
  module Adapters
    class PostgresEra
      # The lineage topology inside one Postgres database: one journal
      # per domain, list-partitioned by era, with a single ordinal
      # sequence spanning partitions (total order across eras is
      # structural); a `hecks_eras` table holding each era's frozen
      # source text, its once-minted hash/label, and the watermark cut
      # into its ancestor; and, per aggregate, a head derived from the
      # journal — never a table anything rewrites.
      #
      # For era 1 the head is a plain view (latest save per id). From
      # era 2 on, the ancestor tail is a materialized view whose
      # definition is the compiled, chained edge sequence — one CTE per
      # original edge, in mint order, never a flattened merged rule set
      # — with the watermark baked into the definition, so post-cut
      # old-era writes cannot leak into the new head even on refresh.
      # Live current-era writes overlay it through the head view.
      #
      # Writing to a superseded schema drops the instant the new one
      # materializes: one shared row policy admits INSERTs to whichever
      # era was just established (era 1 at first hold, era N at mint),
      # and advancing it is part of the same transaction that builds the
      # new era's matview. There is no persisted per-role fork — any
      # granted role, app or the table's own owner (force row level
      # security applies this to the owner too, not only ordinary
      # roles), writes the current era or nothing, from the moment that
      # transaction commits. A stale-era write during the narrow window
      # before that commit — RLS is checked once, when the statement
      # executes, never re-checked at commit, so a transaction that
      # inserted while the old era was still current can still land
      # after a concurrent mint has already moved the fence on — is
      # exactly what diverged_count/merge_tail exist to reconcile; it is
      # the residual of an unavoidable race (ordinals are
      # sequence-assigned, not transactional — see below), not a
      # supported way to keep operating two schemas side by side. Only
      # an actual Postgres superuser (or a role granted BYPASSRLS)
      # sits above force and keeps writing at will, forever.
      #
      # Lineage order is ordinal-assignment order: the ordinal comes from a
      # sequence, and a sequence's `nextval()` is never rolled back with its
      # transaction — accepted and documented rather than papered over.
      #
      # One part of that is closed. Two concurrent plain writes could call
      # `nextval()` in one order and commit in the other — nothing about a
      # single autocommit INSERT statement stops a slower one from finishing
      # after a faster one that started later — so "ordinal order" and
      # "commit order" were formally two different total orders even with no
      # mint anywhere near either write. `PostgresEra#append` now holds
      # `pg_advisory_xact_lock(hashtext('hecks_ordinal:' || domain))` for the
      # length of its own transaction, a different key from `mint_era!` and
      # `merge_tail!`'s `hecks_eras:domain` — so plain writes serialize
      # against each other only, never against a mint, and ordinal order
      # equals commit order for them now.
      #
      # The other part is not, on purpose. A stale-era write during the
      # narrow window before a mint's fence-move commits is the same race by
      # a different name — and closing it would mean a plain write
      # serializing against a mint, which is exactly the guarantee
      # `postgres_lineage_spec.rb`'s "an old checkout keeps writing its own
      # era through a mint" pins the absence of. That race stays the
      # residual `diverged_count`/`merge_tail!` exist to reconcile, not
      # something a plain write should ever block for.
      #
      # One concern per file under lineage/: provisioning (DDL and the
      # RLS posture), era_store (the hecks_eras rows and their integrity),
      # mint_transaction (the one transaction that makes an era real),
      # tail_merge (the one deliberate merge command), resumable_backfill
      # (the one chunked/lock-free/resumable scan loop, shared by
      # head_compiler's own backfill and field_cache's), head_compiler
      # (the chained-edge SQL a head derives through), field_cache (the
      # per-where-field read cache that lets a query skip the reduction
      # entirely), transform_installer (the hecks_tr_* jsonb helpers).
      class Lineage
        include Provisioning
        include EraStore
        include MintTransaction
        include TailMerge
        include ResumableBackfill
        include HeadCompiler
        include FieldCache
        include TransformInstaller

        JOURNAL_COLUMNS = "ordinal, era, aggregate, aggregate_id, operation, state, mirrors".freeze

        # Postgres's own NAMEDATALEN limit: an identifier over 63 bytes is
        # silently truncated, never refused — so two different overlong
        # names that happen to share their first 63 bytes would collide
        # again, at a longer length, the exact same failure mode this
        # whole file exists to close for `storage_name` alone. Domain-
        # qualifying every name below (`qualified_name`, private) makes
        # that reachable in a way it mostly wasn't before (a long domain
        # name stacked onto a long aggregate name). A constant, not
        # private — Ruby constants are never actually scoped by `private`
        # (Lint/UselessConstantScoping), so this stays above it.
        POSTGRES_IDENTIFIER_LIMIT = 63

        attr_reader :db, :domain, :formerly_known_as

        def initialize(db, domain, formerly_known_as: nil)
          @db = db
          @domain = domain.to_s
          @formerly_known_as = formerly_known_as&.to_s
        end

        def journal = "hecks_journal_#{Naming.snake(@domain)}"
        def quoted_journal = quote(journal)
        def sequence = "#{journal}_ordinal"
        def partition(era) = "#{journal}_era_#{era}"
        # Domain-qualified, the same way `journal` already is — see
        # `qualified_name`'s own comment for why this wasn't true until
        # docs/decisions/0059. Two different domains bound to PostgresEra
        # against the same database, each declaring an aggregate whose
        # own name snake_cases to the same storage_name (found live: two
        # unrelated "Note" aggregates), used to derive the exact same
        # `note_head`/`note_head_snapshot_1` physical relations — every
        # boot of the second domain silently clobbered the first's
        # already-compiled head view, `ensure_first_head!`'s own
        # "belt-and-suspenders self-healing" being exactly the mechanism
        # that did it (postgres_era.rb's own comment there).
        def head_view(storage_name) = qualified_name("#{storage_name}_head")
        # The transactionally-upserted read cache behind head_view — one row
        # per live id, keyed by id, carrying the ordinal it was last written
        # at. Scoped by era, not just storage_name — an aggregate that
        # isn't renamed across a mint keeps the same storage_name in both
        # eras, so storage_name alone would have era N+1 sharing one
        # physical table with era N: a freshly-minted era would inherit
        # every pre-mint (and, worse, pre-rekey/pre-translation) row
        # instead of starting empty. era-qualified naming is what
        # `partition`/`matview` already do for exactly this reason.
        def head_snapshot(storage_name, era) = qualified_name("#{storage_name}_head_snapshot_#{era}")
        def matview(storage_name, era, label) = qualified_name("#{storage_name}_lineage_#{era}_#{label}")

        private

        # `@domain`, snake-cased and folded onto `suffix` — human-readable
        # in the ordinary case (every one of these names gets read
        # directly at a psql prompt during a live incident — see
        # docs/decisions/0059's own verification section), degrading to a
        # hashed, truncated form only once the readable form would
        # actually risk exceeding `POSTGRES_IDENTIFIER_LIMIT`. The same
        # trade `Runtime::StorageShape.mint_label` (a bare hash-prefix, no
        # attempt at readability at all — a mint label is never meant to
        # be legible on its own) and `FieldCache#field_cache` (fully
        # hashed, for the same reason) already make elsewhere in this
        # adapter — this one keeps more of the readable form than either,
        # since unlike a mint label or a field-cache table, these names
        # are the ones an operator reads and types by hand.
        def qualified_name(suffix)
          full = "#{Naming.snake(@domain)}_#{suffix}"
          return full if full.bytesize <= POSTGRES_IDENTIFIER_LIMIT

          digest = Digest::SHA256.hexdigest(full)[0, 8]
          "#{full.byteslice(0, POSTGRES_IDENTIFIER_LIMIT - digest.bytesize - 1)}_#{digest}"
        end

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
