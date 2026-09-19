require "open3"
require "pg"

# The QA ledger's own `ROLE`, provisioned the way the operator does it — by
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

  # Builds a connection URL for `database`, authenticated as `ROLE`.
  #
  # @param database [String] name of the database to connect to as `ROLE`
  # @return [String] a `postgres://` connection URL for `database`, authenticated as `ROLE`
  def self.url(database) = "postgres://#{ROLE}@localhost/#{database}"

  # Runs the real `bin/qa_postgres_role` against `database`, run once after it is created.
  #
  # @param database [String] name of the newly created database
  # @return [String] the script's own combined stdout/stderr output, for a spec that wants to
  #   assert on what it reports having done
  # @raise [RuntimeError] if the script exits with a non-zero status
  def self.provision!(database)
    out, status = Open3.capture2e("ruby", SCRIPT, database)
    raise "bin/qa_postgres_role #{database} failed:\n#{out}" unless status.success?

    out
  end

  # Hands the `public` schema back to `ROLE`, run after a
  # `DROP SCHEMA public CASCADE; CREATE SCHEMA public` scrub —
  # the scrub leaves `public` superuser-owned, with create for nobody
  # else; the ledger's next boot has to be able to provision in it.
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
