require "fileutils"
require "tmpdir"
require "open3"
require_relative "postgres_probe"
require_relative "qa_ledger_role"

# A disposable Postgres-backed `QualityControl` ledger for specs that run the `bin/qa_*` scripts
# as subprocesses; one database per spec file so parallel_rspec workers do not scrub each other.
module QaLedgerFixture
  # Mirrors `qa/bluebook/quality_control.hecksagon`, with the `CI`/`IssueTracker` ports unbound.
  HECKSAGON = <<~RUBY.freeze
    Hecks.hecksagon "QualityControl" do
      uses_framework "Governance"

      QualityControl::Target.persisted_by("PostgresEra")
      QualityControl::Sweep.persisted_by("PostgresEra")
      QualityControl::Bug.persisted_by("PostgresEra")
      QualityControl::Angle.persisted_by("PostgresEra")
      QualityControl::Ticket.persisted_by("PostgresEra")
      QualityControl::Patch.persisted_by("PostgresEra")
      QualityControl::Improvement.persisted_by("PostgresEra")
      QualityControl::Clearance.persisted_by("PostgresEra")

      QualityControl::Ticket.port "IssueTracker" do
        asks "File", to: Ticket do
          answers "IssueFiled"
          refuses "IssueFilingRefused"
        end

        tells "Closed", to: Ticket do
          emits "IssueClosedUpstream"
        end
      end

      QualityControl::Clearance.port "CI" do
        asks "Run", to: Clearance do
          answers "SuitePassed"
          refuses "SuiteFailed"
        end
      end
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
      FileUtils.ln_s(File.join(InMemoryDomain::ROOT, "qa/bluebook/quality_control.bluebook"),
                     File.join(@dir, "quality_control.bluebook"))
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

    # A fresh schema before every example, so no rows leak between examples.
    def reset!
      scrub = PG.connect(dbname: @database)
      scrub.exec("DROP SCHEMA public CASCADE")
      scrub.exec("CREATE SCHEMA public")
      scrub.close
      QaLedgerRole.own_public!(@database)
    end

    # Boots in-process to seed or read rows; the script under test always runs as a subprocess.
    def boot
      Hecks.boot(@dir)
    end

    # The subprocess environment; `QA_SWEEP_DOMAIN_DIR` is the seam the `bin/qa_*` scripts honour.
    def env(extra = {})
      { "QA_SWEEP_DOMAIN_DIR" => @dir }.merge(extra)
    end

    # Runs `bundle exec ruby bin/<script>`; returns captured stdout, stderr and status.
    def run(script, *, env: {}, chdir: InMemoryDomain::ROOT)
      Open3.capture3(self.env(env), "bundle", "exec", "ruby", File.join(InMemoryDomain::ROOT, "bin", script), *,
                     chdir: chdir)
    end
  end
end
