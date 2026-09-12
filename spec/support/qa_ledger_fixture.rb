require "fileutils"
require "tmpdir"
require "open3"
require_relative "postgres_probe"
require_relative "qa_ledger_role"

# A DISPOSABLE, POSTGRES-BACKED `QualityControl` LEDGER FOR SPECS THAT
# DRIVE THE REAL `bin/qa_*` SCRIPTS AS SUBPROCESSES — the exact pattern
# `spec/qa_sweep_all_spec.rb` established (read that file's own header
# FIRST for the full reasoning: why Memory cannot serve a cross-process
# claim, why the chapter is symlinked and never copied, why only the
# WIRING is swapped). Extracted here so `spec/qa_tick_spec.rb`,
# `spec/qa_open_pr_spec.rb` and `spec/qa_log_bug_spec.rb` share one
# implementation instead of three drifting copies of the same
# `before(:all)`; `qa_sweep_all_spec.rb` keeps its own, deliberately — it
# also builds a fixture TARGET domain and a fixture Rust crate this
# helper has no reason to know about.
#
# ONE DATABASE PER SPEC FILE (`database:`), so `parallel_rspec` can run
# the callers side by side without one file's `reset!` scrubbing another
# file's rows mid-example. Constants live INSIDE this module on purpose —
# `spec/qa_sweep_persistence_parity_spec.rb`'s own header explains how a
# bare `FIXTURE_HECKSAGON = …` inside an `RSpec.describe` block lands on
# `Object` and silently overwrites every other spec's copy.
module QaLedgerFixture
  # LINE-FOR-LINE `qa/bluebook/quality_control.hecksagon`'s bindings, with
  # the `CI`/`IssueTracker` ports declared but unbound — see
  # `spec/qa_sweep_all_spec.rb`'s `FIXTURE_HECKSAGON` comment on why an
  # unbound port is exactly as dormant here as the real file's own
  # deliberately-unbound `IssueTracker`.
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

  class Ledger
    attr_reader :database, :dir

    def initialize(database:)
      @database = database
    end

    # Creates the database and the fixture directory. Call from
    # `before(:all)`, after a `PostgresProbe.available?` skip.
    def stand_up!
      @root = Dir.mktmpdir("qa_ledger_fixture")
      @dir  = File.join(@root, "bluebook")
      FileUtils.mkdir_p(@dir)
      FileUtils.ln_s(File.join(InMemoryDomain::ROOT, "qa/bluebook/quality_control.bluebook"),
                     File.join(@dir, "quality_control.bluebook"))
      File.write(File.join(@dir, "quality_control.hecksagon"), HECKSAGON)
      # THE SAME URL SHAPE THE REAL LEDGER BINDS, as `hecks_qa`, an
      # ordinary owner role — PostgresEra refuses to boot as the ambient
      # superuser (BUG#24); `bin/qa_postgres_role`, run for real below
      # through `QaLedgerRole`, is what makes the URL connectable.
      File.write(File.join(@dir, "quality_control.world"), <<~RUBY)
        Hecks.world "QualityControl" do
          realm "QA"
          persisted_by("PostgresEra") { database "#{QaLedgerRole.url(@database)}" }
        end
      RUBY

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

    # A FRESH SCHEMA BEFORE EVERY EXAMPLE — a row a prior example left
    # behind must never leak into the next one's own ledger.
    def reset!
      scrub = PG.connect(dbname: @database)
      scrub.exec("DROP SCHEMA public CASCADE")
      scrub.exec("CREATE SCHEMA public")
      scrub.close
      QaLedgerRole.own_public!(@database)
    end

    # Booted IN-PROCESS, briefly, to seed or read rows — never to run
    # the script under test, which is always a real subprocess.
    def boot
      Hecks.boot(@dir)
    end

    # The environment every subprocess gets: the seam `bin/qa_sweep`,
    # `bin/qa_pr_check`, `bin/qa_log_bug`, `bin/qa_open_pr` all honour.
    def env(extra = {})
      { "QA_SWEEP_DOMAIN_DIR" => @dir }.merge(extra)
    end

    # `bundle exec ruby bin/<script> …`, exactly as a human would type it.
    def run(script, *, env: {}, chdir: InMemoryDomain::ROOT)
      Open3.capture3(self.env(env), "bundle", "exec", "ruby", File.join(InMemoryDomain::ROOT, "bin", script), *,
                     chdir: chdir)
    end
  end
end
