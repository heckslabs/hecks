require "hecks/ports/persistence/plugins/era"
require_relative "qa_ledger_fixture"
require "pathname"
require "tmpdir"

# **The `bin/qa_tick` fixture, shared** — extracted from what used to be one
# `qa_tick_spec.rb` (2026-09-18, following the same reasoning
# `spec/support/qa_sweep_all_fixture.rb`'s own header already spells
# out): the file's own 4 examples took 128s together, each a real
# subprocess spawning `bin/qa_pr_check`, `bin/qa_sweep --all`, and
# `bin/qa_generated_domains` as its own nested subprocesses — a floor no
# matrix size could split further since `parallel_rspec` balances at
# file granularity. Splitting the fixture out here and the 4 examples
# across their own small files (each `include_context "with a qa_tick
# fixture", <unique database name>`) lets the shard balancer actually
# spread this file's own work instead of being stuck with one 128s lump.
#
# **Parameterized by database name, not hardcoded** — same per-file-unique-
# resource-name discipline `qa_sweep_all_fixture.rb`'s own header
# requires, for the identical reason: `parallel_rspec` runs different
# files as genuinely concurrent OS processes, so two files sharing one
# ledger database name would race each other's own `CREATE DATABASE`/
# `DROP SCHEMA CASCADE`. `QaLedgerFixture::Ledger#stand_up!`/`#tear_down!`
# are cheap (a tmpdir, a couple of small file writes, one `CREATE
# DATABASE`) relative to the real subprocess-boot cost each example pays
# regardless of how many share a file, so paying that setup once per
# split file instead of once per 4 examples is a good trade.
RSpec.shared_context "with a qa_tick fixture" do |database_name|
  # The same trivially well-behaved target `spec/support/qa_sweep_all_fixture.rb`
  # sweeps — read that file's `FIXTURE_TARGET_BLUEBOOK` comment for why a
  # real corpus domain would make a "clean" example flaky.
  TICK_TARGET_BLUEBOOK = <<~RUBY.freeze
    Hecks.bluebook "QaTickFixtureTarget" do
      vision "A trivially well-behaved sweep target, authored only so this spec's own 'clean' examples never depend on this repository's own live, actively-changing QA corpus."

      aggregate "Widget" do
        description "One numbered widget and a bump count — nothing a fuzzer can ever catch."

        identified_by :reference

        attribute :reference, WidgetReference
        attribute :count,     WidgetCount

        value_object "WidgetReference" do
          attribute :value, String, pattern: '[^ \\t\\n\\r]'
          invariant("a widget is referenced") { !value.to_s.empty? }
        end

        value_object "WidgetCount" do
          attribute :value, Integer, default: 0
          invariant("a count never goes negative") { !value.negative? }
        end

        command "Open" do
          attribute :reference, WidgetReference

          sets :reference

          emits "WidgetOpened"
        end

        command "Bump" do
          reference_to Widget

          sets :count, increment: 1

          emits "WidgetBumped"
        end
      end
    end
  RUBY

  TICK_TARGET_HECKSAGON = <<~RUBY.freeze
    Hecks.hecksagon "QaTickFixtureTarget" do
      QaTickFixtureTarget::Widget.persisted_by("Heki")
    end
  RUBY

  before(:all) do
    skip "no reachable Postgres — start one to run this spec" unless PostgresProbe.available?

    @ledger = QaLedgerFixture::Ledger.new(database: database_name).stand_up!
    @target_domain_dir = Dir.mktmpdir("qa_tick_spec_target-", InMemoryDomain::ROOT)
    File.write(File.join(@target_domain_dir, "fixture.bluebook"), TICK_TARGET_BLUEBOOK)
    File.write(File.join(@target_domain_dir, "fixture.hecksagon"), TICK_TARGET_HECKSAGON)
    @target_domain_relpath = Pathname.new(@target_domain_dir).relative_path_from(Pathname.new(InMemoryDomain::ROOT)).to_s
  end

  after(:all) do
    @ledger&.tear_down!
    FileUtils.remove_entry(@target_domain_dir) if @target_domain_dir
  end

  before do
    @ledger.reset!
    @origin = Dir.mktmpdir("qa_tick_origin")
    @repo   = Dir.mktmpdir("qa_tick_repo")
    system("git", "init", "-q", "--bare", "-b", "main", @origin, out: File::NULL) or raise "bare init failed"
    git("init", "-q", "-b", "main")
    File.write(File.join(@repo, "README"), "one\n")
    git("add", ".")
    git("commit", "-qm", "init")
    git("remote", "add", "origin", @origin)
    git("push", "-q", "origin", "main")
  end

  after do
    FileUtils.remove_entry(@repo) if @repo
    FileUtils.remove_entry(@origin) if @origin
  end

  def git(*args)
    system("git", "-c", "user.name=spec", "-c", "user.email=spec@example.com", *args, chdir: @repo,
           out: File::NULL, err: File::NULL) or raise "git #{args.join(' ')} failed"
  end

  # `QA_GENERATED_DOMAINS_PER_TICK=0` — the generated-domains step runs
  # from the real checkout's dials, which a throwaway tick must not spend
  # minutes generating and building against; zero is its own "off" path.
  def tick
    @ledger.run("qa_tick", env: { "QA_REPO_DIR" => @repo, "QA_GENERATED_DOMAINS_PER_TICK" => "0" })
  end

  def identify!(targets)
    @ledger.boot
    targets.each do |reference, path|
      QualityControl::Target.identify!(reference: { value: reference }, path: { value: path })
    end
  end
end
