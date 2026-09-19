require "pg"

# **A non-superuser owner for a spec's own disposable database** — the kind of
# role PostgresEra's boot now insists on. Its era write-fence is row-level
# security, which the ambient dev/CI Postgres user (a superuser locally;
# `PGUSER: postgres` in CI) walks straight through, so
# `Lineage#check_fence_applies!` refuses to boot as one (BUG#24).
# lineage_spec.rb, reset_spec.rb and field_cache_spec.rb each hand-roll
# exactly this shape for a role of their own (CREATE ROLE ... Login, no
# superuser, no BYPASSRLS; re-grant on `public` after every scrub) because
# the fence is their subject. This is the same shape, shared, for the
# specs that boot a whole domain (`Hecks.boot`, or `LineageManager
# .check!`) against a database they create and drop themselves and whose
# subject is something else — tenancy, a rename, a rekey, a migration.
# Opting those fixtures out with `allow_superuser true` would have been
# one line each; binding a real fenced owner is what keeps every one of
# them booting the way a deployment does.
#
# The role owns the database (alter database ... Owner to): a PostgresEra
# boot provisions — CREATE TABLE, CREATE POLICY, CREATE SCHEMA for a
# `schema:` tenant — and an owner may, where a merely-CONNECTed role may
# not. `own_public!` hands the `public` schema back over after a spec's
# own `DROP SCHEMA public CASCADE; CREATE SCHEMA public` scrub, which
# leaves it superuser-owned with create for nobody else (lineage_spec.rb's
# own `before` comment found this first).
#
# **One ROLE name for every caller, never dropped**. `parallel_rspec` runs
# these files concurrently: creation is race-safe (the do block swallows
# the loser's error — duplicate_object once the winner has committed,
# unique_violation on pg_authid_rolname_index when both are still in
# flight; see bin/qa_postgres_role), and a drop ROLE while another spec's
# database still hangs off it would fail anyway. There is nothing to
# clean — the role owns nothing once each disposable database is dropped.
module FencedOwner
  ROLE = "hecks_spec_owner".freeze

  def self.url(database) = "postgres://#{ROLE}@localhost/#{database}"

  # After create database, on the ambient admin connection.
  def self.own!(database)
    admin = PG.connect(dbname: "postgres")
    admin.exec(<<~SQL)
      DO $$ BEGIN
        CREATE ROLE #{ROLE} LOGIN NOSUPERUSER NOBYPASSRLS NOCREATEDB NOCREATEROLE;
      EXCEPTION WHEN duplicate_object OR unique_violation THEN NULL;
      END $$
    SQL
    admin.exec("ALTER DATABASE #{admin.quote_ident(database)} OWNER TO #{ROLE}")
    admin.close
    own_public!(database)
  end

  # After a `DROP SCHEMA public CASCADE; CREATE SCHEMA public` scrub.
  def self.own_public!(database)
    db = PG.connect(dbname: database)
    db.exec("ALTER SCHEMA public OWNER TO #{ROLE}")
    db.close
  end
end
