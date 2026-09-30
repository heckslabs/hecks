require "hecks/ports/persistence/plugins/era"
require_relative "qa_ledger_fixture"
require_relative "qa_lib_cli"
require "pathname"
require "tmpdir"

# Shared fixture for the `hecks quality_control tick` specs; pass a per-file unique database name.
# Files run as concurrent processes, so a shared name would race on create/drop.
RSpec.shared_context "with a qa_tick fixture" do |database_name|
  # The trivial target from qa_sweep_all_fixture.rb, so "clean" examples avoid the live corpus.
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

  # Runs `git` in the throwaway `@repo` checkout.
  def git(*args)
    system("git", "-c", "user.name=spec", "-c", "user.email=spec@example.com", *args, chdir: @repo,
           out: File::NULL, err: File::NULL) or raise "git #{args.join(' ')} failed"
  end

  # Zero generated domains per tick: a throwaway tick must not spend minutes building them.
  def tick
    QaLibCli.run(@ledger, "qa_tick", env: { "QA_REPO_DIR" => @repo, "QA_GENERATED_DOMAINS_PER_TICK" => "0" })
  end

  # Boots the fixture ledger in-process only to write `Target` rows.
  def identify!(targets)
    @ledger.boot
    targets.each do |reference, path|
      QualityControl::Target.identify!(reference: { value: reference }, path: { value: path })
    end
  end
end
