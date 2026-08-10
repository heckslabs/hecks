require "json"
require "digest"

require_relative "lineage/provisioning"
require_relative "lineage/era_store"
require_relative "lineage/mint_transaction"
require_relative "lineage/tail_merge"
require_relative "lineage/head_compiler"
require_relative "lineage/transform_installer"
require_relative "../../../naming"

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
      # Writing to a superseded schema drops the instant the new one
      # materializes: ONE shared row policy admits INSERTs to whichever
      # era was just established (era 1 at first hold, era N at mint),
      # and advancing it is part of the SAME transaction that builds the
      # new era's matview. There is no persisted per-role fork — any
      # granted role, app or the table's own OWNER (FORCE ROW LEVEL
      # SECURITY applies this to the owner too, not only ordinary
      # roles), writes the current era or nothing, from the moment that
      # transaction commits. A stale-era write during the narrow window
      # before that commit — RLS is checked once, when the statement
      # EXECUTES, never re-checked at commit, so a transaction that
      # inserted while the old era was still current can still land
      # after a concurrent mint has already moved the fence on — is
      # exactly what diverged_count/merge_tail exist to reconcile; it is
      # the residual of an unavoidable race (ordinals are
      # sequence-assigned, not transactional — see below), not a
      # supported way to keep operating two schemas side by side. Only
      # an actual Postgres superuser (or a role granted BYPASSRLS)
      # sits above FORCE and keeps writing at will, forever.
      #
      # Lineage order is ordinal-assignment order: the ordinal comes from a
      # sequence, and a sequence's `nextval()` is never rolled back with its
      # transaction — accepted and documented rather than papered over.
      #
      # ONE PART OF THAT IS CLOSED. Two concurrent PLAIN writes could call
      # `nextval()` in one order and COMMIT in the other — nothing about a
      # single autocommit INSERT statement stops a slower one from finishing
      # after a faster one that started later — so "ordinal order" and
      # "commit order" were formally two different total orders even with no
      # mint anywhere near either write. `Postgres#append` now holds
      # `pg_advisory_xact_lock(hashtext('hecks_ordinal:' || domain))` for the
      # length of its own transaction, a DIFFERENT key from `mint_era!` and
      # `merge_tail!`'s `hecks_eras:domain` — so plain writes serialize
      # against EACH OTHER only, never against a mint, and ordinal order
      # equals commit order for them now.
      #
      # THE OTHER PART IS NOT, ON PURPOSE. A stale-era write during the
      # narrow window before a mint's fence-move commits is the SAME race by
      # a different name — and closing it would mean a plain write
      # serializing against a mint, which is exactly the guarantee
      # `postgres_lineage_spec.rb`'s "an old checkout keeps writing its own
      # era THROUGH a mint" pins the ABSENCE of. That race stays the
      # residual `diverged_count`/`merge_tail!` exist to reconcile, not
      # something a plain write should ever block for.
      #
      # One concern per file under lineage/: provisioning (DDL and the
      # RLS posture), era_store (the hecks_eras rows and their integrity),
      # mint_transaction (the one transaction that makes an era real),
      # tail_merge (the one deliberate merge command), head_compiler (the
      # chained-edge SQL a head derives through), transform_installer
      # (the hecks_tr_* jsonb helpers).
      class Lineage
        include Provisioning
        include EraStore
        include MintTransaction
        include TailMerge
        include HeadCompiler
        include TransformInstaller

        JOURNAL_COLUMNS = "ordinal, era, aggregate, aggregate_id, operation, state, mirrors".freeze

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
        def head_view(storage_name) = "#{storage_name}_head"
        # The transactionally-upserted read cache behind head_view — one row
        # per LIVE id, keyed by id, carrying the ordinal it was last written
        # at. Scoped by ERA, not just storage_name — an aggregate that
        # ISN'T renamed across a mint keeps the SAME storage_name in both
        # eras, so storage_name alone would have era N+1 sharing one
        # physical table with era N: a freshly-minted era would inherit
        # every pre-mint (and, worse, pre-rekey/pre-translation) row
        # instead of starting empty. era-qualified naming is what
        # `partition`/`matview` already do for exactly this reason.
        def head_snapshot(storage_name, era) = "#{storage_name}_head_snapshot_#{era}"
        def matview(storage_name, era, label) = "#{storage_name}_lineage_#{era}_#{label}"

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
