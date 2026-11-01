require_relative "../../../../naming"
require_relative "../../../../runtime/errors"
require_relative "domain_rename_state"

module Hecks
  module Adapters
    class PostgresEra
      class Lineage
        # The domain rename bridge: moves a domain's journal, sequence, partitions and lineage
        # rows from its `formerly_known_as` name to the current one. Only the rename entry point
        # (`Era.RenameDomain`) moves them; a boot or a provisioning that finds the move pending
        # refuses by name (`refuse_pending_rename!`), so no history starts fresh beside the old.
        module DomainRename
          include DomainRenameState

          # Moves a domain's journal, sequence, partitions, lineage rows, heads and field caches
          # from `formerly_known_as` to the current name, in one transaction.
          #
          # A no-op when `hecks_eras` is missing, the new name has rows, or the former name has
          # none. Locks go in a fixed order (old before new, eras before ordinal).
          #
          # @param storage_names [Array<String>] the storage names of the domain's aggregates
          # @param cache_fields [Hash{String => Array<String>}] each aggregate's storage name mapped
          #   to the where-fields its queries cache, whose tables hash the domain
          # @return [Integer] how many eras moved; 0 when nothing was pending
          # @raise [Runtime::WiringError] if the locks are not granted within 10s or Postgres
          #   refuses a statement (prechecks included); both roll back first
          def rename_domain!(storage_names: [], cache_fields: {})
            rename_pending? ? rename_in_transaction!(storage_names, cache_fields) : 0
          rescue PG::LockNotAvailable
            rollback_quietly
            raise Runtime::WiringError,
                  "cannot rename #{@formerly_known_as} to #{@domain}: another rename, mint, or write holds " \
                  "one of the domain locks — waited 10s; try again shortly"
          rescue PG::Error => e
            rollback_quietly
            raise Runtime::WiringError, "cannot rename #{@formerly_known_as} to #{@domain}: #{e.message.strip}"
          end

          # Tells whether the history sits under the former name while the current name holds none.
          #
          # @return [Boolean] false with no prior name, no eras table, eras under the current name,
          #   or none under the former name
          # @raise [PG::Error] if the lookup fails
          def rename_pending?
            return false unless @formerly_known_as
            return false unless @db.exec_params("SELECT to_regclass($1)", ["hecks_eras"])[0]["to_regclass"]
            return false if domain_rows?(@domain)

            domain_rows?(@formerly_known_as)
          end

          # Refuses, by name, to go on while the rename is pending.
          #
          # @return [void]
          # @raise [Runtime::WiringError] if `rename_pending?`
          def refuse_pending_rename!
            return unless rename_pending?

            raise Runtime::WiringError,
                  "cannot boot #{@domain}: its history is held under the former name #{@formerly_known_as} " \
                  "and #{@domain} holds none; rename the domain with era.rename_domain first " \
                  "(`hecks era.rename_domain! domain=<domain directory> --confirm`)"
          end

          private

          def domain_rows?(domain)
            @db.exec_params("SELECT 1 FROM hecks_eras WHERE domain = $1 LIMIT 1", [domain]).ntuples.positive?
          end

          # The locks come first and the eras are read after them, so a mint that lands before the
          # locks are granted has its partition renamed with the rest; the pending check is made
          # again under the locks for a rename that finished while this one waited.
          def rename_in_transaction!(storage_names, cache_fields)
            @db.exec("BEGIN")
            @db.exec("SET LOCAL lock_timeout = '10s'")
            rename_lock_keys.each { |key| @db.exec_params("SELECT pg_advisory_xact_lock(hashtext($1))", [key]) }
            return finish_without_moving unless rename_pending?

            eras = former_eras
            move_everything!(eras, storage_names, cache_fields)
            @db.exec("COMMIT")
            eras.size
          end

          def finish_without_moving
            @db.exec("ROLLBACK")
            0
          end

          def move_everything!(eras, storage_names, cache_fields)
            rename_relations!("hecks_journal_#{Naming.snake(@formerly_known_as)}", eras.map(&:first))
            rename_heads!(storage_names, eras)
            rename_catalogue_relations!
            rename_field_caches!(cache_fields, eras.map(&:first))
            rename_rows!
          end

          # The former name's eras as [ordinal, label] pairs, oldest first.
          def former_eras
            @db.exec_params(
              "SELECT ordinal, label FROM hecks_eras WHERE domain = $1 ORDER BY ordinal", [@formerly_known_as]
            ).map { |row| [row["ordinal"].to_i, row["label"]] }
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

          # Renames each aggregate's head view, per-era snapshot tables and translated-tail views;
          # ALTER TABLE renames a view as it does a table, and the view keeps its snapshot by oid.
          def rename_heads!(storage_names, eras)
            former = self.class.new(@db, @formerly_known_as)
            storage_names.each do |name|
              rename_relation!(former.head_view(name), head_view(name))
              eras.each { |ordinal, label| rename_era_heads!(former, name, ordinal, label) }
            end
          end

          def rename_era_heads!(former, name, ordinal, label)
            rename_relation!(former.head_snapshot(name, ordinal), head_snapshot(name, ordinal))
            rename_relation!(former.matview(name, ordinal, label), matview(name, ordinal, label)) if label
          end
        end
      end
    end
  end
end
