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
      # The lineage topology inside one Postgres database: a journal per domain, partitioned by
      # era, with each aggregate's head derived from it rather than stored.
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

        # Longer identifiers are silently truncated by Postgres, so `qualified_name` hashes them.
        POSTGRES_IDENTIFIER_LIMIT = 63

        attr_reader :db, :domain, :formerly_known_as

        # @param db [PG::Connection] open connection to the database holding the domain's journal
        # @param domain [String, Symbol] the domain's declared name; every relation name and
        #   advisory-lock key derives from it
        # @param formerly_known_as [String, Symbol, nil] the domain's prior name, which makes
        #   `ensure_base!` rename its relations and rows first; nil when there is no prior name
        def initialize(db, domain, formerly_known_as: nil)
          @db = db
          @domain = domain.to_s
          @formerly_known_as = formerly_known_as&.to_s
        end

        # Names the domain's one journal table, the partitioned parent of every era's rows.
        #
        # @return [String] unquoted relation name, `hecks_journal_` plus the snake-cased domain
        def journal = "hecks_journal_#{Naming.snake(@domain)}"

        # Quotes the journal's name for direct interpolation into SQL.
        #
        # @return [String] `journal` as a double-quoted Postgres identifier
        def quoted_journal = quote(journal)

        # Names the sequence that assigns journal ordinals across every era's partition.
        #
        # @return [String] unquoted sequence name, `journal` plus `_ordinal`
        def sequence = "#{journal}_ordinal"

        # Names the journal partition that holds one era's rows.
        #
        # @param era [Integer] the era's ordinal, 1-based
        # @return [String] unquoted relation name, `journal` plus `_era_` and the ordinal
        def partition(era) = "#{journal}_era_#{era}"

        # Names the view an aggregate's current state is read through.
        #
        # Domain-qualified so two domains sharing an aggregate name do not clobber each other.
        #
        # @param storage_name [String] the aggregate's snake-cased storage name
        # @return [String] unquoted view name, at most `POSTGRES_IDENTIFIER_LIMIT` bytes
        def head_view(storage_name) = qualified_name("#{storage_name}_head")

        # Names the snapshot table that backs one aggregate's head within one era.
        #
        # Era-scoped so a new era starts empty, not with the previous era's rows.
        #
        # @param storage_name [String] the aggregate's snake-cased storage name
        # @param era [Integer] ordinal of the era the snapshot belongs to
        # @return [String] unquoted table name, at most `POSTGRES_IDENTIFIER_LIMIT` bytes
        def head_snapshot(storage_name, era) = qualified_name("#{storage_name}_head_snapshot_#{era}")

        # Names the materialized view holding an aggregate's translated ancestor tail for one era.
        #
        # @param storage_name [String] the aggregate's snake-cased storage name
        # @param era [Integer] ordinal of the era the view was compiled for
        # @param label [String] the era's minted label, a prefix of its shape hash
        # @return [String] unquoted matview name, at most `POSTGRES_IDENTIFIER_LIMIT` bytes
        def matview(storage_name, era, label) = qualified_name("#{storage_name}_lineage_#{era}_#{label}")

        private

        # Snake-cased domain folded onto `suffix`; hashed and truncated only past the length limit.
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
