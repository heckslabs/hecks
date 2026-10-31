require "spec_helper"
require "fileutils"
require "open3"
require "rbconfig"
require "tmpdir"
require "hecks/tools/project_cli"
require_relative "support/postgres_probe"
require_relative "support/qa_ledger_fixture"

# `exe/hecks quality_control …` boots the QA ledger's own directory, where the ledger binds
# PostgresEra, as the rotation does through `Hecks::Corpus::ROTATION_LEDGER`. It does not boot the
# Hecks domain, which binds nothing and so stores in Memory. The launcher runs from a disposable
# root whose `qa/bluebook` is a throwaway PostgresEra ledger, so the real rows are never touched.
RSpec.describe "exe/hecks quality_control reads the QA ledger", :io do
  ROUTE_LEDGER_DATABASE = "hecks_qa_quality_control_route_spec".freeze

  # The launcher as `hecks project_cli` writes it for the checkout's own `exe/hecks`.
  def self.generated_launcher
    Hecks::Tools::ProjectCli.launcher("lib/hecks/hecks", "Hecks", "hecks project_cli",
                                      executable: "exe/hecks", ledgers: Hecks::Corpus::ROTATION_LEDGER)
  end

  before(:all) do
    skip "no reachable Postgres — start one to run this spec" unless PostgresProbe.available?

    @ledger = QaLedgerFixture::Ledger.new(database: ROUTE_LEDGER_DATABASE).stand_up!
    @root = Dir.mktmpdir("quality_control_launcher_route_spec")
    FileUtils.mkdir_p([File.join(@root, "exe"), File.join(@root, "qa")])
    FileUtils.ln_s(File.join(InMemoryDomain::ROOT, "lib"), File.join(@root, "lib"))
    FileUtils.ln_s(@ledger.dir, File.join(@root, "qa", "bluebook"))
    File.write(File.join(@root, "exe", "hecks"), self.class.generated_launcher)
  end

  after(:all) do
    @ledger&.tear_down!
    FileUtils.remove_entry(@root) if @root
  end

  before { @ledger.reset! }

  def run_launcher(*args)
    Open3.capture3(RbConfig.ruby, File.join(@root, "exe", "hecks"), *args, chdir: @root)
  end

  def identify_target
    _out, err, status = run_launcher("quality_control", "Target.identify!", "reference.value=route-spec",
                                     "path.value=examples/route_spec", "--wait")
    expect(status).to be_success, err
  end

  def query_targets
    out, err, status = run_launcher("quality_control", "query", "Target.all")
    expect(status).to be_success, err
    out
  end

  it "names the QA ledger directory as the boot for quality_control" do
    expect(self.class.generated_launcher).to include(%("quality_control" => "qa/bluebook"))
  end

  it "writes a target to the disposable ledger and reads it back in a fresh process" do
    identify_target
    expect(query_targets).to include("route-spec")
  end
end
