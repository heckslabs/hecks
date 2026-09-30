require "open3"
require "pg"
require "hecks/quality_control/cli/child"

# Provisions the QA ledger's owner role by running the real `qa_postgres_role` command.
# PostgresEra refuses to boot over a superuser connection, so the ledger connects as `hecks_qa`.
# Sibling of `FencedOwner`, which hand-rolls the role for non-QA fixtures.
module QaLedgerRole
  ROLE   = "hecks_qa".freeze
  ROOT   = File.expand_path("../..", __dir__)

  def self.url(database) = "postgres://#{ROLE}@localhost/#{database}"

  def self.provision!(database)
    out, status = Open3.capture2e(*Hecks::QualityControlCli::Child.argv(ROOT, "qa_postgres_role", database))
    raise "qa_postgres_role #{database} failed:\n#{out}" unless status.success?

    out
  end

  # The scrub leaves `public` superuser-owned; the ledger's next boot must be able to create in it.
  def self.own_public!(database)
    db = PG.connect(dbname: database)
    db.exec("ALTER SCHEMA public OWNER TO #{ROLE}")
    db.close
  end
end
