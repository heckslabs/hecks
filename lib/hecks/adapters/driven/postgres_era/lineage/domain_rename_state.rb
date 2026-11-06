module Hecks
  module Adapters
    class PostgresRevision
      class Lineage
        # What a domain rename moves besides the journal: every table keyed by the domain's name,
        # the head objects found in the catalogue (not by the aggregates the bluebook lists now, so
        # an aggregate since removed moves too), the field caches whose names hash the domain, and
        # the backfill cursors that name the renamed relations.
        module DomainRenameState
          # Tables with a `domain` column, moved by name when they exist.
          DOMAIN_TABLES = %w[hecks_eras hecks_era_texts hecks_attestations hecks_ledger_archives
                             hecks_saga_instances].freeze

          # The suffixes of the relations a domain's heads and archives are named with.
          HEAD_SUFFIX = /\A(?<storage>.+?)_(?<kind>head|head_snapshot_\d+|lineage_\d+_[^_]+|archived_\d+)\z/

          private

          def rename_rows!
            DOMAIN_TABLES.each do |table|
              next unless relation?(table)

              @db.exec_params("UPDATE #{table} SET domain = $1 WHERE domain = $2", [@domain, @formerly_known_as])
            end
            rename_archive_names!
          end

          # An archive table moved with its domain prefix, so its list says where it is now.
          def rename_archive_names!
            return unless relation?("hecks_ledger_archives")

            @db.exec_params(
              "UPDATE hecks_ledger_archives SET archive = $3 || substr(archive, $4) " \
              "WHERE domain = $1 AND left(archive, $4 - 1) = $2",
              [@domain, "#{former_prefix}_", "#{current_prefix}_", former_prefix.length + 2]
            )
          end

          def relation?(name) = !@db.exec_params("SELECT to_regclass($1)", [quote(name)])[0]["to_regclass"].nil?

          def former_prefix = Naming.snake(@formerly_known_as)

          def current_prefix = Naming.snake(@domain)

          # Renames each head, snapshot, matview and archive the catalogue holds under the former
          # prefix, leaving alone those that belong to another domain whose name extends it.
          def rename_catalogue_relations!
            catalogue_relations.each do |name|
              rename_relation!(name, name.sub(/\A#{Regexp.escape(former_prefix)}_/, "#{current_prefix}_"))
            end
          end

          def catalogue_relations
            others = other_prefixes
            names = @db.exec_params(
              "SELECT relname FROM pg_class WHERE relkind IN ('r', 'v', 'm') AND relname LIKE $1 " \
              "AND pg_table_is_visible(oid) ORDER BY relname", ["#{former_prefix.gsub("_", "\\_")}\\_%"]
            ).map { |row| row["relname"] }
            names.select { |name| head_name?(name) && others.none? { |other| name.start_with?("#{other}_") } }
          end

          def head_name?(name) = name.delete_prefix("#{former_prefix}_").match?(HEAD_SUFFIX)

          # Prefixes of other held domains that extend the former name and so would match it.
          def other_prefixes
            held = @db.exec_params("SELECT DISTINCT domain FROM hecks_eras WHERE domain NOT IN ($1, $2)",
                                   [@formerly_known_as, @domain]).map { |row| Naming.snake(row["domain"]) }
            held.select { |other| other.start_with?("#{former_prefix}_") }
          end

          # The field caches for each cached field of each aggregate, under every held era.
          def rename_field_caches!(cache_fields, ordinals)
            former = self.class.new(@db, @formerly_known_as)
            cache_fields.each do |storage, fields|
              ordinals.product(fields) do |ordinal, field|
                rename_cache!(former.field_cache(storage, ordinal, field), field_cache(storage, ordinal, field))
              end
            end
          end

          def rename_cache!(from, to)
            rename_relation!(from, to)
          end

          # Renames a table, view or materialized view, the indexes named after it and its cursor.
          def rename_relation!(from, to)
            return unless relation?(from)

            @db.exec("ALTER TABLE #{quote(from)} RENAME TO #{quote(to)}")
            rename_progress!(from, to)
            %w[_value_idx _reduce_idx _pkey].each { |suffix| rename_index!("#{from}#{suffix}", "#{to}#{suffix}") }
          end

          def rename_index!(from, to)
            @db.exec("ALTER INDEX #{quote(from)} RENAME TO #{quote(to)}") if relation?(from)
          end

          # The backfill cursor follows its relation, so a renamed snapshot is not filled afresh.
          def rename_progress!(from, to)
            return unless relation?("hecks_backfill_progress")

            @db.exec_params("UPDATE hecks_backfill_progress SET target = $2 WHERE target = $1", [from, to])
          end
        end
      end
    end
  end
end
