require "spec_helper"

# `PlainSession.Retire` through the booted Hecks domain, with a fake `Sessions` port in place of
# `ClaudeSessions`: the port reads the facts and the bluebook judges them.
RSpec.describe "PlainSession.Retire through the Sessions port" do
  before(:all) { @hecks = boot_hecks_in_memory }

  let(:withdrawn) { [] }

  def fake_port(bound:, pinned:, working:)
    facts = { run: bound ? "r1" : "", bound: bound, pinned: pinned, working: working, note: "session s1" }
    log = withdrawn
    port = Object.new
    port.define_singleton_method(:examine) { |**| facts }
    port.define_singleton_method(:withdraw) { |session:| (log << session).last && { retired_at: { value: "now" } } }
    allow(Hecks::Adapters::ClaudeSessions).to receive(:new).and_return(port)
  end

  def retire(id)
    argv = ["plain_session.retire!", "session.value=#{id}", "--wait"]
    Hecks::Adapters::Driving::CliRunner.call(runtime: @hecks, argv: argv, program: "hecks")
  end

  it "retires a session bound to no run, even one named for a pinned role" do
    fake_port(bound: false, pinned: true, working: true)
    retire("s1")

    expect(withdrawn.size).to eq(1)
  end

  it "retires the session of an ended run" do
    fake_port(bound: false, pinned: false, working: false)
    retire("s2")

    expect(withdrawn.size).to eq(1)
  end

  it "refuses the bound session of a pinned role's live run" do
    fake_port(bound: true, pinned: true, working: false)
    retire("s3")

    expect(withdrawn).to be_empty
  end

  it "refuses a session that is working on a run" do
    fake_port(bound: true, pinned: false, working: true)
    retire("s4")

    expect(withdrawn).to be_empty
  end
end
