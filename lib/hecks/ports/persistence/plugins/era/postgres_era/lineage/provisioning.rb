require_relative "base_sql"
require_relative "domain_rename"

module Hecks
  module Adapters
    class PostgresEra
      class Lineage
        # Owner-only schema bootstrap: lineage tables, the RLS fence, the domain rename
        # bridge, and per-era journal partitions.
        module Provisioning
          include BaseSql
          include DomainRename

          # Builds or tops up this domain's lineage schema when the connected role owns the
          # journal (or none exists yet); any other role only attempts the rename bridge.
          #
          # ALTER TABLE and REVOKE are owner-only, so a non-owner app role must skip them to boot.
          #
          # @return [void]
          # @raise [Runtime::WiringError] if the `formerly_known_as` rename cannot take
          #   its locks within 10s or Postgres refuses one of its statements
          # @raise [PG::Error] if Postgres refuses a provisioning statement
          def ensure_base!
            rename_domain! if @formerly_known_as
            return unless provisioner?

            create_lineage_tables!
            create_journal!
            ensure_partition!(1)
            revoke_journal_mutation!
            force_row_security!
            install_transforms!
          end

          # Refuses to boot on a connection whose role Postgres exempts from row-level security
          # (a superuser or BYPASSRLS role) unless the caller opts in.
          #
          # Those roles bypass the write-fence, so a stale checkout could keep writing a
          # superseded era unnoticed. With `allow_superuser` it boots and warns on stderr.
          #
          # @param allow_superuser [Boolean, Object, nil] any truthy value boots anyway
          #   with a warning on stderr; `false` or `nil` refuses
          # @return [nil] when the role is fenced, or after the warning is written
          # @raise [Runtime::WiringError] if the connection's role is a superuser or is
          #   granted BYPASSRLS, and `allow_superuser` is not truthy
          # @raise [PG::Error] if the `pg_roles` lookup fails
          def check_fence_applies!(allow_superuser: false)
            row = @db.exec("SELECT rolname, rolsuper, rolbypassrls FROM pg_roles WHERE rolname = current_user")[0]
            exempt = fence_exemptions(row)
            return if exempt.empty?

            role = row["rolname"].inspect
            refuse_unfenced_role!(role, exempt) unless allow_superuser
            warn_unfenced_role(role, exempt)
          end

          # Tells whether this connection's role is the one that builds the schema:
          # it owns the domain's journal, or no journal is visible yet.
          #
          # @return [Boolean] true when no journal table is visible on the search path
          #   or `current_user` owns it; false when another role owns it
          # @raise [PG::Error] if the catalog lookup fails
          def provisioner?
            rows = @db.exec_params(
              "SELECT pg_get_userbyid(relowner) = current_user AS owned FROM pg_class " \
              "WHERE relname = $1 AND pg_table_is_visible(oid)",
              [journal]
            )
            rows.ntuples.zero? || rows[0]["owned"] == "t"
          end

          # Creates and attaches one era's journal partition, unless it is already
          # attached; finishes the attach for a table a crashed boot left detached.
          #
          # Build then ATTACH, never CREATE ... PARTITION OF: the latter takes an
          # AccessExclusiveLock on the parent and stops every writer for the whole mint,
          # while ATTACH takes only ShareUpdateExclusiveLock, so a running checkout keeps
          # writing through the build.
          #
          # @param era [Integer] ordinal of the era whose partition is ensured
          # @return [void]
          # @raise [PG::Error] if Postgres refuses the create or the attach
          def ensure_partition!(era)
            return if partition_attached?(era)

            @db.exec(format(PARTITION_SQL, partition: quote(partition(era)), journal: quoted_journal))
            @db.exec(format(ATTACH_PARTITION_SQL, journal: quoted_journal, partition: quote(partition(era)), era: era.to_i))
          end

          # Tells whether an era's partition is part of the journal, by asking
          # `pg_inherits` rather than checking that the table exists.
          #
          # A table left by a crash between CREATE and ATTACH exists but is not attached,
          # and the next boot must finish the job.
          #
          # @param era [Integer] ordinal of the era whose partition is looked up
          # @return [Boolean] true when the partition is attached to this domain's
          #   journal; false when it is missing or exists unattached
          # @raise [PG::Error] if the catalog lookup fails
          def partition_attached?(era)
            @db.exec_params(
              "SELECT 1 FROM pg_inherits i " \
              "JOIN pg_class child ON child.oid = i.inhrelid " \
              "JOIN pg_class parent ON parent.oid = i.inhparent " \
              "WHERE child.relname = $1 AND parent.relname = $2 " \
              "AND pg_table_is_visible(child.oid) AND pg_table_is_visible(parent.oid)",
              [partition(era), journal]
            ).ntuples.positive?
          end

          private

          def create_lineage_tables!
            @db.exec(ERAS_SQL)
            @db.exec("ALTER TABLE hecks_eras ADD COLUMN IF NOT EXISTS held_digest text")
            @db.exec("ALTER TABLE hecks_eras ADD COLUMN IF NOT EXISTS held_projection jsonb")
            # Canonical-form version that minted the name (Runtime::StorageShape::FORM_VERSION);
            # NULL reads as 1.
            @db.exec("ALTER TABLE hecks_eras ADD COLUMN IF NOT EXISTS canon_form int")
            @db.exec(ERA_TEXTS_SQL)
            @db.exec(APPROVALS_SQL)
          end

          def create_journal!
            @db.exec("CREATE SEQUENCE IF NOT EXISTS #{quote(sequence)}")
            @db.exec(format(JOURNAL_SQL, journal: quoted_journal, sequence: sequence))
          end

          # Journal rows are immutable by privilege: nothing updates or deletes them.
          # The REVOKE is guarded because it rewrites pg_class.relacl and takes a lock
          # even when nothing changes, so concurrent reboots would race into
          # `tuple concurrently updated`.
          #
          # The guard is `relacl IS NULL`, not has_table_privilege('public', ..., 'UPDATE'):
          # a new table already answers "no UPDATE", so that check would skip the first
          # REVOKE and leave relacl NULL forever. pg_table_is_visible(oid), not a bare
          # relname match, so a sibling schema's same-named table is never mistaken for ours.
          def revoke_journal_mutation!
            relacl_null = @db.exec_params(
              "SELECT relacl IS NULL FROM pg_class WHERE relname = $1 AND pg_table_is_visible(oid)", [journal]
            ).getvalue(0, 0)
            @db.exec("REVOKE UPDATE, DELETE ON #{quoted_journal} FROM PUBLIC") if relacl_null == "t"
          end

          # RLS goes on at provisioning, never mid-life: enabling it later would deny
          # every role that has no policy yet.
          #
          # FORCE, not just enable, or the table owner is exempt from every policy. A
          # superuser or BYPASSRLS role stays exempt regardless (see check_fence_applies!).
          #
          # Guarded: enable/FORCE takes an AccessExclusiveLock even as a no-op, and this
          # runs on every boot, so an unconditional reissue would freeze concurrent writers.
          def force_row_security!
            current = @db.exec_params(
              "SELECT relrowsecurity, relforcerowsecurity FROM pg_class " \
              "WHERE relname = $1 AND pg_table_is_visible(oid)", [journal]
            )[0]
            @db.exec("ALTER TABLE #{quoted_journal} ENABLE ROW LEVEL SECURITY") unless current["relrowsecurity"] == "t"
            @db.exec("ALTER TABLE #{quoted_journal} FORCE ROW LEVEL SECURITY") unless current["relforcerowsecurity"] == "t"
          end

          def fence_exemptions(row)
            exempt = []
            exempt << "a superuser" if row["rolsuper"] == "t"
            exempt << "granted BYPASSRLS" if row["rolbypassrls"] == "t"
            exempt
          end

          def refuse_unfenced_role!(role, exempt)
            raise Runtime::WiringError,
                  "cannot boot #{@domain}: PostgresEra's era write-fence is row-level security, and this " \
                  "connection's role #{role} is #{exempt.join(" and ")} — Postgres exempts it from every " \
                  "policy, FORCE included, so an old checkout connected this way keeps writing a superseded " \
                  "era and nothing refuses. Connect as an ordinary role instead (database " \
                  "\"postgres://<role>@<host>/<db>\" in the .world — a non-superuser OWNER still provisions " \
                  "and mints), or declare `allow_superuser true` in the same persisted_by block to boot with " \
                  "the fence void, on the record."
          end

          def warn_unfenced_role(role, exempt)
            warn "[hecks] #{@domain}: booting PostgresEra as #{role}, #{exempt.join(" and ")}, under " \
                 "allow_superuser — the era write-fence is void for this connection; only this process's own " \
                 "superseded-era check (PostgresEra#append) stands between an old checkout and a superseded era"
          end

          # Abandons the open transaction, ignoring a failure of the rollback itself.
          def rollback_quietly
            @db.exec("ROLLBACK")
          rescue StandardError
            nil
          end
        end
      end
    end
  end
end
