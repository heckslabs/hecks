require "fileutils"
require "tmpdir"
require "open3"
require_relative "postgres_probe"
require_relative "qa_ledger_role"

# A disposable, Postgres-backed `QualityControl` ledger for specs that
# drive the real `bin/qa_*` scripts as subprocesses — the exact pattern
# `spec/support/qa_sweep_all_fixture.rb` established (read that file's own header
# first for the full reasoning: why Memory cannot serve a cross-process
# claim, why the chapter is symlinked and never copied, why only the
# wiring is swapped). Extracted here so `spec/qa_tick_spec.rb`,
# `spec/qa_open_pr_spec.rb` and `spec/qa_log_bug_spec.rb` share one
# implementation instead of three drifting copies of the same
# `before(:all)`; `qa_sweep_all_fixture.rb` keeps its own, deliberately — it
# also builds a fixture target domain and a fixture Rust crate this
# helper has no reason to know about.
#
# One database per spec file (`database:`), so `parallel_rspec` can run
# the callers side by side without one file's `reset!` scrubbing another
# file's rows mid-example. Constants live inside this module on purpose —
# `spec/qa_sweep_persistence_parity_spec.rb`'s own header explains how a
# bare `FIXTURE_HECKSAGON = …` inside an `RSpec.describe` block lands on
# `Object` and silently overwrites every other spec's copy.
module QaLedgerFixture
  # Line-for-line `qa/bluebook/quality_control.hecksagon`'s bindings, with
  # the `CI`/`IssueTracker` ports declared but unbound — see
  # `spec/support/qa_sweep_all_fixture.rb`'s `FIXTURE_HECKSAGON` comment on why an
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

  # One spec file's own disposable, Postgres-backed `QualityControl` ledger: its own database,
  # its own symlinked fixture bluebook directory, and the subprocess plumbing (`#run`, `#env`)
  # every `bin/qa_*` script under test is driven through.
  class Ledger
    attr_reader :database, :dir

    # @param database [String] name of this spec file's own disposable Postgres database
    def initialize(database:)
      @database = database
    end

    # Creates the database and the fixture directory. Call from
    # `before(:all)`, after a `PostgresProbe.available?` skip.
    #
    # @return [QaLedgerFixture::Ledger] self, once the database, fixture directory, and QA
    #   role are provisioned
    def stand_up!
      @root = Dir.mktmpdir("qa_ledger_fixture")
      @dir  = File.join(@root, "bluebook")
      FileUtils.mkdir_p(@dir)
      FileUtils.ln_s(File.join(InMemoryDomain::ROOT, "qa/bluebook/quality_control.bluebook"),
                     File.join(@dir, "quality_control.bluebook"))
      File.write(File.join(@dir, "quality_control.hecksagon"), HECKSAGON)
      # The same URL shape the real ledger binds, as `hecks_qa`, an
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

    # Drops the database and removes the fixture directory.
    #
    # @return [void]
    def tear_down!
      admin = PG.connect(dbname: "postgres")
      admin.exec("DROP DATABASE IF EXISTS #{@database} WITH (FORCE)")
      admin.close
      FileUtils.remove_entry(@root) if @root
    end

    # Scrubs the database back to an empty `public` schema, owned again by the QA role.
    #
    # A fresh schema before every example — a row a prior example left
    # behind must never leak into the next one's own ledger.
    #
    # @return [void]
    def reset!
      scrub = PG.connect(dbname: @database)
      scrub.exec("DROP SCHEMA public CASCADE")
      scrub.exec("CREATE SCHEMA public")
      scrub.close
      QaLedgerRole.own_public!(@database)
    end

    # Boots the ledger's fixture domain in-process, to seed or read rows directly.
    #
    # Booted in-process, briefly, to seed or read rows — never to run
    # the script under test, which is always a real subprocess.
    #
    # @return [Runtime::Dispatcher] the dispatcher bound to the fixture domain
    def boot
      Hecks.boot(@dir)
    end

    # Builds the environment every subprocess gets: the seam `bin/qa_sweep`,
    # `bin/qa_pr_check`, `bin/qa_log_bug`, `bin/qa_open_pr` all honour.
    #
    # @param extra [Hash] additional environment entries, merged over the default and
    #   overriding it on a key collision
    # @return [Hash{String => String}] `"QA_SWEEP_DOMAIN_DIR"` pointing at the fixture
    #   directory, plus any `extra` entries
    def env(extra = {})
      { "QA_SWEEP_DOMAIN_DIR" => @dir }.merge(extra)
    end

    # Runs one of the `bin/qa_*` scripts as a real subprocess, `bundle exec ruby bin/<script>
    # …`, exactly as a human would type it. Any further positional arguments are forwarded to
    # the script as its own command-line arguments.
    #
    # @param script [String] basename of the script under `bin/` to run
    # @param env [Hash] additional environment entries, merged into `#env`'s default
    # @param chdir [String] directory to run the subprocess from
    # @return [Array(String, String, Process::Status)] the subprocess's stdout, stderr, and
    #   exit status, per `Open3.capture3`
    def run(script, *, env: {}, chdir: InMemoryDomain::ROOT)
      Open3.capture3(self.env(env), "bundle", "exec", "ruby", File.join(InMemoryDomain::ROOT, "bin", script), *,
                     chdir: chdir)
    end
  end
end
