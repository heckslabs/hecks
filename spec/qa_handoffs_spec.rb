require "spec_helper"
require "fileutils"
require "tmpdir"
require "hecks/quality_control/cli/qa_event_pump"

# The handoffs between the QA ledger and the domains it attaches: Coder's submission reaches the
# maintenance start, and a durable domain's runs survive a fresh boot. The fixtures are disposable.
RSpec.describe "QA handoffs" do
  HANDOFF_LEDGER_DIR = File.expand_path("../lib/hecks/quality_control", __dir__)
  HANDOFF_CODER_DIR = File.expand_path("../lib/hecks/coder", __dir__)

  DURABLE_BLUEBOOK = <<~RUBY.freeze
    Hecks.bluebook "Durable" do
      vision "Keeps runs."

      aggregate "Maintenance" do
        description "A run that must survive a boot."

        attribute :run, MaintenanceRun
        identified_by :run

        value_object "MaintenanceRun" do
          attribute :value, String
          invariant("a run is named") { !value.to_s.empty? }
        end

        command "Start" do
          attribute :run, MaintenanceRun
          sets :run
          emits "Started"
        end

        query "All" do
          description "Every run held."
        end
      end
    end
  RUBY

  def handoff_ledger
    Hecks::QualityControlCli::QaEventPump::Attached.new(
      root: HANDOFF_LEDGER_DIR, dirs: { "QualityControl" => HANDOFF_LEDGER_DIR, "Coder" => HANDOFF_CODER_DIR }
    ).runtime("QualityControl")
  end

  def coder_submission
    Hecks::Runtime::Event.new(name: "WorkSubmitted", aggregate: "Submission", id: "submission-1",
                              payload: { branch: "qa/handoffs", sha: "abc123" })
  end

  it "subscribes the ledger to Coder.WorkSubmitted" do
    expect(handoff_ledger.registry.hecksagon("QualityControl").subscriptions).to include("Coder.WorkSubmitted")
  end

  it "delivers Coder's WorkSubmitted to StartOnSubmission" do
    names = handoff_ledger.outbox.policies_for(coder_submission, "Coder").map { |policy, _home| policy.name }

    expect(names).to include("StartOnSubmission")
  end

  def durable_runs_after_restart(root)
    dir = File.join(root, "durable")
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "durable.bluebook"), DURABLE_BLUEBOOK)
    File.write(File.join(dir, "durable.hecksagon"), %(Hecks.hecksagon "Durable" do\n  persisted_by "Heki"\nend\n))
    Hecks.boot(dir).dispatch_flat("Durable::Maintenance.Start", run: "run-1")
    Hecks.boot(dir).query("Durable::Maintenance.All").map { |row| row[:run][:value] }
  end

  it "keeps a run written before a restart after a fresh boot of the durable domain" do
    Dir.mktmpdir("durable") { |root| expect(durable_runs_after_restart(root)).to eq(["run-1"]) }
  end
end
