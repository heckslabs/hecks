require "pg"

# A non-superuser owner for a spec's own disposable database — the kind of
# role PostgresEra's boot now insists on.
#
# ## Why a non-superuser owner
#
# Its era write-fence is row-level
# security, which the ambient dev/CI Postgres user (a superuser locally;
# `PGUSER: postgres` in CI) walks straight through, so
# `Lineage#check_fence_applies!` refuses to boot as one (BUG#24).
# lineage_spec.rb, reset_spec.rb and field_cache_spec.rb each hand-roll
# exactly this shape for a role of their own (CREATE ROLE ... LOGIN, no
# superuser, no BYPASSRLS; re-grant on `public` after every scrub) because
# the fence is their subject. This is the same shape, shared, for the
# specs that boot a whole domain (`Hecks.boot`, or `LineageManager
# .check!`) against a database they create and drop themselves and whose
# subject is something else — tenancy, a rename, a rekey, a migration.
# Opting those fixtures out with `allow_superuser true` would have been
# one line each; binding a real fenced owner is what keeps every one of
# them booting the way a deployment does.
#
# ## What the ownership grant is for
#
# The role owns the database (ALTER database ... OWNER TO): a PostgresEra
# boot provisions — CREATE TABLE, CREATE POLICY, CREATE SCHEMA for a
# `schema:` tenant — and an owner may, where a merely-CONNECTed role may
# not. `own_public!` hands the `public` schema back over after a spec's
# own `DROP SCHEMA public CASCADE; CREATE SCHEMA public` scrub, which
# leaves it superuser-owned with create for nobody else (lineage_spec.rb's
# own `before` comment found this first).
#
# ## Concurrency and cleanup
#
# One `ROLE` name for every caller, never dropped. `parallel_rspec` runs
# these files concurrently: creation is race-safe (the do block swallows
# the loser's error — duplicate_object once the winner has committed,
# unique_violation on pg_authid_rolname_index when both are still in
# flight; see bin/qa_postgres_role), and dropping `ROLE` while another spec's
# database still hangs off it would fail anyway. There is nothing to
# clean — the role owns nothing once each disposable database is dropped.
module FencedOwner
  ROLE = "hecks_spec_owner".freeze

  # Builds a connection URL for `database`, authenticated as `ROLE`.
  #
  # @param database [String] name of the database to connect to as `ROLE`
  # @return [String] a `postgres://` connection URL for `database`, authenticated as `ROLE`
  def self.url(database) = "postgres://#{ROLE}@localhost/#{database}"

  # Makes `ROLE` the owner of `database` and hands back the `public` schema, run once on the
  # ambient admin connection right after the database is created.
  #
  # @param database [String] name of the newly created database
  # @return [void]
  # @raise [PG::Error] if the admin connection or one of its statements fails
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

  # Hands the `public` schema back to `ROLE`, run after a spec's own
  # `DROP SCHEMA public CASCADE; CREATE SCHEMA public` scrub.
  #
  # @param database [String] name of the database whose `public` schema was just scrubbed
  # @return [void]
  # @raise [PG::Error] if the connection or the `ALTER SCHEMA` statement fails
  def self.own_public!(database)
    db = PG.connect(dbname: database)
    db.exec("ALTER SCHEMA public OWNER TO #{ROLE}")
    db.close
  end
end
