require_relative "../../../../../../naming"
require_relative "../../../../../../runtime/errors"

module Hecks
  module Adapters
    class PostgresEra
      class Lineage
        # The domain rename bridge: moves a domain's journal, sequence, partitions and lineage
        # rows from its `formerly_known_as` name to the current one.
        module DomainRename
          # Moves a domain's journal, sequence, partitions and lineage rows from
          # `formerly_known_as` to the current name, in one transaction.
          #
          # Runs before `provisioner?` and the CREATE TABLE calls in `ensure_base!`; a no-op when
          # `hecks_eras` is missing, the new name has rows, or the former name has none.
          # Locks go in a fixed order (old before new, eras before ordinal) so nothing deadlocks.
          #
          # @return [void]
          # @raise [Runtime::WiringError] if the locks are not granted within 10s or Postgres
          #   refuses a statement (prechecks included); both roll back first
          def rename_domain!
            rename_in_transaction! if rename_pending?
          rescue PG::LockNotAvailable
            rollback_quietly
            raise Runtime::WiringError,
                  "cannot rename #{@formerly_known_as} to #{@domain}: another rename, mint, or write holds " \
                  "one of the domain locks — waited 10s; try again shortly"
          rescue PG::Error => e
            rollback_quietly
            raise Runtime::WiringError, "cannot rename #{@formerly_known_as} to #{@domain}: #{e.message.strip}"
          end

          private

          def rename_pending?
            return false unless @db.exec_params("SELECT to_regclass($1)", ["hecks_eras"])[0]["to_regclass"]
            return false if domain_rows?(@domain)

            domain_rows?(@formerly_known_as)
          end

          def domain_rows?(domain)
            @db.exec_params("SELECT 1 FROM hecks_eras WHERE domain = $1 LIMIT 1", [domain]).ntuples.positive?
          end

          def rename_in_transaction!
            old_journal = "hecks_journal_#{Naming.snake(@formerly_known_as)}"
            ordinals = @db.exec_params(
              "SELECT ordinal FROM hecks_eras WHERE domain = $1 ORDER BY ordinal", [@formerly_known_as]
            ).map { |row| row["ordinal"].to_i }

            @db.exec("BEGIN")
            @db.exec("SET LOCAL lock_timeout = '10s'")
            rename_lock_keys.each { |key| @db.exec_params("SELECT pg_advisory_xact_lock(hashtext($1))", [key]) }
            rename_relations!(old_journal, ordinals)
            rename_rows!
            @db.exec("COMMIT")
          end

          def rename_lock_keys
            [
              "hecks_eras:#{@formerly_known_as}", "hecks_eras:#{@domain}",
              "hecks_ordinal:#{@formerly_known_as}", "hecks_ordinal:#{@domain}"
            ]
          end

          def rename_relations!(old_journal, ordinals)
            @db.exec("ALTER TABLE #{quote(old_journal)} RENAME TO #{quote(journal)}")
            # The sequence is a plain create sequence, not owned by the column, so it
            # does not move with the table and needs its own rename.
            @db.exec("ALTER SEQUENCE #{quote("#{old_journal}_ordinal")} RENAME TO #{quote(sequence)}")
            # Renaming the parent does not rename its partitions.
            ordinals.each do |ordinal|
              @db.exec("ALTER TABLE #{quote("#{old_journal}_era_#{ordinal}")} RENAME TO #{quote(partition(ordinal))}")
            end
          end

          def rename_rows!
            %w[hecks_eras hecks_era_texts hecks_approvals].each do |table|
              @db.exec_params("UPDATE #{table} SET domain = $1 WHERE domain = $2", [@domain, @formerly_known_as])
            end
            # hecks_attestations is created lazily on first reattest!, so it may not exist.
            return unless @db.exec_params("SELECT to_regclass($1)", ["hecks_attestations"])[0]["to_regclass"]

            @db.exec_params("UPDATE hecks_attestations SET domain = $1 WHERE domain = $2", [@domain, @formerly_known_as])
          end
        end
      end
    end
  end
end
