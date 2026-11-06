require "spec_helper"
require_relative "support/registry_double"
require "hecks/hecks/adapters/dispatching"

# Dispatch.Watch: the bloated rows are listed (a dry run does nothing); with confirm the session is
# stopped when it can be and the row yields with the rule as the reason. The brief names the limits.
RSpec.describe Hecks::Adapters::Dispatching::Watcher do
  let(:breach) { Hecks::Adapters::IterationWatch::Breach.new("qa/x", "waiting", "waited 27 min of 15") }
  let(:launcher) { instance_double(Hecks::Adapters::Dispatching::Launcher, check: nil, yield_back: "yielded qa/x: bloat: waiting: waited 27 min of 15") }
  let(:stopper) { instance_double(Proc, call: nil) }
  let(:runs) { { "qa/x" => { status: "started", condition: "", session: "abc123" } } }

  def watcher(found = [breach]) = described_class.new(found, runs, launcher, stopper: stopper)

  describe "a dry run" do
    it "lists the row and what it would do" do
      expect(watcher.call(confirm: false).join("\n")).to include("bloated qa/x [waiting]", "would stop session abc123", "bloat: waiting: waited 27 min of 15")
    end

    it "stops and yields nothing", :aggregate_failures do
      watcher.call(confirm: false)

      expect(stopper).not_to have_received(:call)
      expect(launcher).not_to have_received(:yield_back)
    end

    it "says when nothing is bloated" do
      expect(watcher([]).call(confirm: false)).to eq(["nothing is bloated"])
    end
  end

  describe "with confirm" do
    it "stops the session and yields the row with the rule as the reason", :aggregate_failures do
      watcher.call(confirm: true)

      expect(stopper).to have_received(:call).with("abc123")
      expect(launcher).to have_received(:yield_back).with("qa/x", "bloat: waiting: waited 27 min of 15")
    end

    it "reports that it cannot stop a session and still yields the row", :aggregate_failures do
      allow(stopper).to receive(:call).and_raise(Hecks::Adapters::ConsoleCapture::Failure, "claude stop refused")

      expect(watcher.call(confirm: true).join("\n")).to include("cannot stop qa/x: tell the owner (claude stop refused)")
      expect(launcher).to have_received(:yield_back)
    end

    it "yields only, and says so, when no session is recorded", :aggregate_failures do
      said = described_class.new([breach], {}, launcher, stopper: stopper).call(confirm: true).join("\n")

      expect(said).to include("cannot stop qa/x: tell the owner (no running session")
      expect(stopper).not_to have_received(:call)
    end
  end
end

RSpec.describe Hecks::Adapters::Dispatching::BriefText do
  let(:limits) { Hecks::Adapters::IterationWatch::Setting::Limits.new(3, 15, 1.5, 45) }
  let(:brief) { { "outcome" => "Do it", "restraints" => "Stop after {attempts} attempts; wait {wait_minutes} minutes; budget {budget} minutes." } }

  it "fills the attempts, the waiting and the budget from the settings" do
    expect(described_class.new(brief).render("qa/x", budget: 90, watch: limits)).to include("Stop after 3 attempts; wait 15 minutes; budget 90 minutes.")
  end

  it "falls back to the default budget" do
    expect(described_class.new(brief).render("qa/x", watch: limits)).to include("budget 45 minutes")
  end
end

RSpec.describe "Dispatch.Watch and Work.bloat through the bluebook" do
  let(:hecks) { boot_hecks_in_memory }
  let(:claimed) { Time.utc(2026, 11, 1, 9, 0, 0) }

  def cli(*argv)
    out, = Hecks::Adapters::Driving::CliRunner.call(runtime: hecks, program: "hecks", argv: argv)
    out
  end

  it "Work.bloat lists a started row past its budget", :aggregate_failures do
    cli("tickets", "work.plan!", "work.value=qa/z", "title.value=Z")
    cli("tickets", "work.start!", "to=qa/z", "claimed_by.value=s", "claimed_at.value=#{claimed.iso8601}")
    allow(Hecks::Ports::Clock).to receive(:now).and_return(claimed.to_i + (71 * 60))

    expect(cli("tickets", "work.bloat").to_s).to include("qa/z [budget]: 71 of 45 min")
  end

  it "the config reader shows the setting" do
    expect(Hecks::Adapters::SettingsReading.new.settings(domain: "lib/hecks/hecks")[:text]).to include("iteration watch: 3 attempts, 15 minutes waiting")
  end
end
