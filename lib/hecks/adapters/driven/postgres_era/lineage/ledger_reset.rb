require "json"
require "digest"

module Hecks
  module Adapters
    class PostgresEra
      class Lineage
        # The writes a disposable ledger's boot makes in place of a mint: it re-holds the latest era
        # at the booting shape, gives an aggregate a head that reads only its latest era, and moves
        # an aggregate's rows into a dated archive table so it starts empty. Nothing is dropped:
        # archived rows stay in their table, and each archive is listed in `hecks_ledger_archives`.
        module LedgerReset
          # The list of every archive a disposable ledger's boot made.
          ARCHIVES_SQL = <<~SQL.freeze
            CREATE TABLE IF NOT EXISTS hecks_ledger_archives (
              domain      text NOT NULL,
              aggregate   text NOT NULL,
              archive     text NOT NULL PRIMARY KEY,
              row_count   bigint NOT NULL,
              archived_at timestamptz NOT NULL DEFAULT now()
            )
          SQL

          # The update that re-holds an era at a new shape.
          REHOLD_SQL = "UPDATE hecks_eras SET held_text = $3, held_digest = $4, held_projection = $5::text::jsonb, " \
                       "hash = $6, label = $7, canon_form = $8 WHERE domain = $1 AND ordinal = $2".freeze

          # Moves every journal row of one aggregate, from every era, into a new table named for it
          # and the time, then empties the aggregate's head snapshots, all in one transaction.
          # The journal is locked against writers for the whole move, so no row can commit between
          # the copy and the delete, and the delete must remove exactly the rows the copy holds or
          # the transaction rolls back. A name already taken gets `_2`, `_3`, and so on; an archive
          # is never overwritten.
          #
          # @param storage_name [String] the aggregate's snake-cased storage name
          # @param stamp [String] the time the archive is named for, as `YYYYMMDDHHMMSS`
          # @return [Array(String, Integer)] the archive table's name and how many rows it holds
          # @raise [PG::Error] if Postgres refuses a statement; nothing is moved then
          # @raise [Runtime::WiringError] if the delete removed other rows than the copy holds
          def archive_aggregate!(storage_name, stamp)
            archive = nil
            nested_transaction("hecks_ledger_archive") do
              lock_journal!
              archive = unused_archive_name(storage_name, stamp)
              move_rows!(storage_name, archive)
            end
            [archive, archived_count(archive)]
          end

          # Points an aggregate's head view at its snapshot in `era` alone, with no ancestor tail,
          # creating the snapshot when it is missing. Used for an aggregate whose rows are all in
          # that era: one just added, or one just archived.
          #
          # @param storage_name [String] the aggregate's snake-cased storage name
          # @param era [Integer] the ordinal of the latest held era
          # @return [void]
          # @raise [PG::Error] if Postgres refuses a statement
          def fresh_head!(storage_name, era)
            ensure_head_snapshot!(storage_name, era)
            tokens = { head_view: quote(head_view(storage_name)), snapshot: quote(head_snapshot(storage_name, era)) }
            nested_transaction("hecks_fresh_head") do
              @db.exec("DROP VIEW IF EXISTS #{quote(head_view(storage_name))}")
              @db.exec(format(SqlTemplates::FIRST_HEAD_VIEW_SQL, tokens))
            end
          end

          # Replaces the latest era's held text, digest, projection and name with the booting
          # shape's, recording the old and new digests in `hecks_attestations`.
          #
          # @param ordinal [Integer] the latest held era
          # @param text [String] the booting bluebook's source text
          # @param projection [Hash] the booting bluebook's storage shape
          # @param hash [String] the booting shape's mint hash
          # @return [void]
          # @raise [PG::Error] if Postgres refuses a statement
          def rehold!(ordinal, text, projection, hash)
            fresh = Digest::SHA256.hexdigest(text)
            @db.exec(EraIntegrity::CREATE_ATTESTATIONS_SQL)
            record_attestation!(ordinal, raw_era(ordinal)&.fetch(:held_digest), fresh)
            @db.exec_params(REHOLD_SQL, [@domain, ordinal, text, fresh, JSON.generate(projection), hash,
                                         hash[0, Runtime::StorageShape::LABEL_LENGTH],
                                         Runtime::StorageShape::FORM_VERSION])
            archive_text!(ordinal, text)
          end

          private

          # Blocks every concurrent insert, update and delete on the journal until the transaction
          # ends; reads go on. A writer that waits here lands its row in the journal after the move.
          def lock_journal! = @db.exec("LOCK TABLE #{quoted_journal} IN SHARE ROW EXCLUSIVE MODE")

          def move_rows!(storage_name, archive)
            @db.exec("CREATE TABLE #{quote(archive)} AS SELECT * FROM #{quoted_journal} " \
                     "WHERE aggregate = #{text_literal(storage_name)}")
            record_archive!(storage_name, archive)
            verify_moved!(archive, delete_journal_rows!(storage_name))
            empty_head_snapshots!(storage_name)
          end

          # A delete of a row the archive does not hold would lose it; refuse and roll back.
          def verify_moved!(archive, deleted)
            return if deleted == archived_count(archive)

            raise Runtime::WiringError, "the ledger archive #{archive} holds #{archived_count(archive)} rows but " \
                                        "#{deleted} were deleted from the journal; nothing was moved"
          end

          def archived_count(archive) = @db.exec("SELECT count(*) FROM #{quote(archive)}")[0]["count"].to_i

          # The archive's name, suffixed `_2`, `_3` and on while a table or listed archive has it.
          def unused_archive_name(storage_name, stamp)
            @db.exec(ARCHIVES_SQL)
            base = "#{storage_name}_archived_#{stamp}"
            (1..).lazy.map { |n| qualified_name(n == 1 ? base : "#{base}_#{n}") }.find { |name| archive_name_free?(name) }
          end

          def archive_name_free?(name)
            return false if table_exists?(quote(name))

            @db.exec_params("SELECT 1 FROM hecks_ledger_archives WHERE archive = $1", [name]).ntuples.zero?
          end

          def record_archive!(storage_name, archive)
            @db.exec(ARCHIVES_SQL)
            @db.exec_params("INSERT INTO hecks_ledger_archives (domain, aggregate, archive, row_count) " \
                            "SELECT $1, $2, $3, count(*) FROM #{quote(archive)}", [@domain, storage_name, archive])
          end

          # The journal forces row-level security with no DELETE policy, so even its owner deletes
          # nothing; a policy that admits this one aggregate's rows stands for the one statement.
          def delete_journal_rows!(storage_name)
            aggregate = text_literal(storage_name)
            @db.exec("CREATE POLICY hecks_ledger_archive ON #{quoted_journal} FOR DELETE TO PUBLIC " \
                     "USING (aggregate = #{aggregate})")
            deleted = @db.exec("DELETE FROM #{quoted_journal} WHERE aggregate = #{aggregate}").cmd_tuples
            @db.exec("DROP POLICY hecks_ledger_archive ON #{quoted_journal}")
            deleted
          end

          def empty_head_snapshots!(storage_name)
            eras.each do |era|
              snapshot = head_snapshot(storage_name, era[:ordinal])
              @db.exec("TRUNCATE #{quote(snapshot)}") if table_exists?(snapshot)
            end
          end
        end
      end
    end
  end
end
