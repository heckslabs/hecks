require "open3"
require "pg"

# Provisions the QA ledger's owner role by running the real `bin/qa_postgres_role`.
# PostgresEra refuses to boot over a superuser connection, so the ledger connects as `hecks_qa`.
# Sibling of `FencedOwner`, which hand-rolls the role for non-QA fixtures.
module QaLedgerRole
  ROLE   = "hecks_qa".freeze
  SCRIPT = File.expand_path("../../bin/qa_postgres_role", __dir__)

  def self.url(database) = "postgres://#{ROLE}@localhost/#{database}"

  def self.provision!(database)
    out, status = Open3.capture2e("ruby", SCRIPT, database)
    raise "bin/qa_postgres_role #{database} failed:\n#{out}" unless status.success?

    out
  end

  # The scrub leaves `public` superuser-owned; the ledger's next boot must be able to create in it.
  def self.own_public!(database)
    db = PG.connect(dbname: database)
    db.exec("ALTER SCHEMA public OWNER TO #{ROLE}")
    db.close
  end
end
