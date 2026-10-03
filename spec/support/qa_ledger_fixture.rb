require "fileutils"
require "tmpdir"
require "open3"
require "hecks/quality_control/cli/child"
require_relative "postgres_probe"
require_relative "qa_ledger_role"

# A disposable Postgres-backed `QualityControl` ledger for specs that run the `qa_*` commands
# as subprocesses; one database per spec file so parallel_rspec workers do not scrub each other.
module QaLedgerFixture
  # Mirrors the ledger wiring in `qa/bluebook/quality_control.hecksagon`, chapter ports included.
  HECKSAGON = <<~RUBY.freeze
    Hecks::Chapters.load!("QualityControl")

    Hecks.hecksagon "QualityControl" do
      attaches "Governance"

      QualityControl::Target.persisted_by("PostgresEra")
      QualityControl::Sweep.persisted_by("PostgresEra")
      QualityControl::Bug.persisted_by("PostgresEra")
      QualityControl::Angle.persisted_by("PostgresEra")
      QualityControl::Ticket.persisted_by("PostgresEra")
      QualityControl::Patch.persisted_by("PostgresEra")
      QualityControl::Improvement.persisted_by("PostgresEra")
      QualityControl::Clearance.persisted_by("PostgresEra")
    end
  RUBY

  # A real Postgres database plus a fixture domain directory that symlinks the real chapter.
  class Ledger
    attr_reader :database, :dir

    def initialize(database:)
      @database = database
    end

    # Creates the database and the fixture directory; call from `before(:all)`.
    #
    # @return [QaLedgerFixture::Ledger] self
    def stand_up!
      @root = Dir.mktmpdir("qa_ledger_fixture")
      @dir  = File.join(@root, "bluebook")
      FileUtils.mkdir_p(@dir)
      File.write(File.join(@dir, "quality_control.hecksagon"), HECKSAGON)
      File.write(File.join(@dir, "context_map.hecksagon"), InMemoryDomain::GOVERNANCE_POSTGRES_ERA_HECKSAGON)
      # PostgresEra refuses to boot as a superuser; connect as the role `QaLedgerRole` provisions.
      url = QaLedgerRole.url(@database)
      File.write(File.join(@dir, "quality_control.world"), <<~RUBY)
        Hecks.world "QualityControl" do
          realm "QA"
          persisted_by("PostgresEra") { database "#{url}" }
        end
      RUBY
      File.write(File.join(@dir, "governance.world"), InMemoryDomain.governance_postgres_era_world(url))

      admin = PG.connect(dbname: "postgres")
      admin.exec("DROP DATABASE IF EXISTS #{@database} WITH (FORCE)")
      admin.exec("CREATE DATABASE #{@database}")
      admin.close
      QaLedgerRole.provision!(@database)
      self
    end

    def tear_down!
      admin = PG.connect(dbname: "postgres")
      admin.exec("DROP DATABASE IF EXISTS #{@database} WITH (FORCE)")
      admin.close
      FileUtils.remove_entry(@root) if @root
    end

    # Clears rows before every example so none leak between examples, via `truncate`
    # rather than dropping and recreating the schema: dropping it would invalidate
    # `#boot`'s memoized connection below, which stays bound to the same tables for a
    # whole file's lifetime. Measured: dropping/recreating the schema itself costs under
    # 20ms — a `#boot` call costs ~0.3-0.4s, almost entirely re-parsing the same static
    # bluebook domain, so paying that once per file instead of once per example is the
    # real saving here. A no-op the first time this runs, before `#boot` has provisioned
    # any tables yet.
    def reset!
      scrub = PG.connect(dbname: @database)
      tables = scrub.exec("SELECT tablename FROM pg_tables WHERE schemaname = 'public'").map { |row| row["tablename"] }
      unless tables.empty?
        quoted = tables.map { |table| scrub.quote_ident(table) }.join(", ")
        scrub.exec("TRUNCATE #{quoted} RESTART IDENTITY CASCADE")
      end
      scrub.close
    end

    # Boots in-process to seed or read rows; the script under test always runs as a
    # subprocess. Memoized, since the domain this boots never changes within one spec
    # file's lifetime — see `#reset!`'s own comment for the cost this avoids repeating.
    def boot
      @boot ||= Hecks.boot(@dir)
    end

    # The subprocess environment; `QA_SWEEP_DOMAIN_DIR` is the seam the `qa_*` commands honour.
    def env(extra = {})
      { "QA_SWEEP_DOMAIN_DIR" => @dir }.merge(extra)
    end

    # Runs one `QualityControlCli::Child` command; returns captured stdout, stderr and status.
    def run(script, *, env: {}, chdir: InMemoryDomain::ROOT)
      Open3.capture3(self.env(env), *Hecks::QualityControlCli::Child.argv(InMemoryDomain::ROOT, script, *),
                     chdir: chdir)
    end
  end
end
