require "pg"

# A non-superuser owner for a spec's disposable database, so PostgresEra's row-level-security
# write fence applies: `Lineage#check_fence_applies!` refuses to boot as a superuser.
#
# The role owns the database because a PostgresEra boot provisions tables, policies and schemas.
# One `ROLE` serves every caller and is never dropped: `parallel_rspec` runs files concurrently,
# creation swallows the race-loser's error (see bin/qa_postgres_role), and dropping it would fail
# while another spec's database still hangs off it.
module FencedOwner
  ROLE = "hecks_spec_owner".freeze

  def self.url(database) = "postgres://#{ROLE}@localhost/#{database}"

  # Call after `create database`, on the ambient admin connection.
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

  # Call after a `DROP SCHEMA public CASCADE; CREATE SCHEMA public` scrub.
  def self.own_public!(database)
    db = PG.connect(dbname: database)
    db.exec("ALTER SCHEMA public OWNER TO #{ROLE}")
    db.close
  end
end
