require_relative "qa_lib_cli"
require "pg"

# Provisions the QA ledger's owner role by running the real
# `hecks quality_control create_ledger_role`.
# PostgresEra refuses to boot over a superuser connection, so the ledger connects as `hecks_qa`.
# Sibling of `FencedOwner`, which hand-rolls the role for non-QA fixtures.
module QaLedgerRole
  ROLE = "hecks_qa".freeze

  def self.url(database) = "postgres://#{ROLE}@localhost/#{database}"

  def self.provision!(database)
    out, status = QaLibCli.capture2e("qa_postgres_role", database)
    raise "create_ledger_role #{database} failed:\n#{out}" unless status.success?

    out
  end

  # The scrub leaves `public` superuser-owned; the ledger's next boot must be able to create in it.
  def self.own_public!(database)
    db = PG.connect(dbname: database)
    db.exec("ALTER SCHEMA public OWNER TO #{ROLE}")
    db.close
  end
end
