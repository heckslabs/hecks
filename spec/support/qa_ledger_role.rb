require "open3"
require "pg"

# THE QA LEDGER'S OWN ROLE, PROVISIONED THE WAY THE OPERATOR DOES IT — by
# running the real `bin/qa_postgres_role` against a spec's disposable
# database, never a re-implementation of it. `qa/bluebook/quality_control
# .world` binds `postgres://hecks_qa@localhost/hecks_quality_control`,
# and that script is the one documented step that makes the URL
# connectable (BUG#24: PostgresEra refuses to boot over a superuser
# connection, so the ledger connects as an ordinary owner role instead).
# The specs that boot a QualityControl fixture against their own
# database run the exact same script against it first, then bind the
# exact same URL shape — so the round trip an operator is asked to trust
# on the live ledger is the one CI proves on every run.
#
# Sibling to `FencedOwner` (spec/support/fenced_owner.rb), which is the
# shared hand-rolled role for fixtures that are not the QA ledger; this
# one exists so the QA fixtures exercise the shipped script itself.
module QaLedgerRole
  ROLE   = "hecks_qa".freeze
  SCRIPT = File.expand_path("../../bin/qa_postgres_role", __dir__)

  def self.url(database) = "postgres://#{ROLE}@localhost/#{database}"

  # After CREATE DATABASE. Returns the script's own output, for a spec
  # that wants to assert on what it reports having done.
  def self.provision!(database)
    out, status = Open3.capture2e("ruby", SCRIPT, database)
    raise "bin/qa_postgres_role #{database} failed:\n#{out}" unless status.success?

    out
  end

  # After a `DROP SCHEMA public CASCADE; CREATE SCHEMA public` scrub —
  # the scrub leaves `public` superuser-owned, with CREATE for nobody
  # else; the ledger's next boot has to be able to provision in it.
  def self.own_public!(database)
    db = PG.connect(dbname: database)
    db.exec("ALTER SCHEMA public OWNER TO #{ROLE}")
    db.close
  end
end
