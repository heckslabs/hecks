require "spec_helper"

# A fake `Sessions` port and the `plain_session.retire!` call, shared by the examples below.
module RetireThroughFakePort
  def withdrawn = (@withdrawn ||= [])

  def fake_port(bound:, pinned:, working:)
    facts = { run: bound ? "r1" : "", bound: bound, pinned: pinned, working: working, note: "session s1" }
    log = withdrawn
    port = Object.new
    port.define_singleton_method(:examine) { |**| facts }
    port.define_singleton_method(:withdraw) { |session:| (log << session).last && { retired_at: { value: "now" } } }
    allow(Hecks::Adapters::ClaudeSessions).to receive(:new).and_return(port)
  end

  def retire(id, **facts)
    fake_port(**facts)
    argv = ["plain_session.retire!", "session.value=#{id}", "--wait"]
    Hecks::Adapters::Driving::CliRunner.call(runtime: @hecks, argv: argv, program: "hecks")
    withdrawn.size
  end
end

# `PlainSession.Retire` through the booted Hecks domain, with a fake `Sessions` port in place of
# `ClaudeSessions`: the port reads the facts and the bluebook judges them.
RSpec.describe "PlainSession.Retire through the Sessions port" do
  include RetireThroughFakePort

  before(:all) { @hecks = boot_hecks_in_memory }

  it "retires a session bound to no run that no pinned role names, even a working one" do
    expect(retire("s1", bound: false, pinned: false, working: true)).to eq(1)
  end

  it "retires the session of an ended run" do
    expect(retire("s2", bound: false, pinned: false, working: false)).to eq(1)
  end

  it "refuses the bound session of a pinned role's live run" do
    expect(retire("s3", bound: true, pinned: true, working: false)).to eq(0)
  end

  it "refuses the session of a pinned role even when it holds no run" do
    expect(retire("s5", bound: false, pinned: true, working: true)).to eq(0)
  end

  it "refuses a session that is working on a run" do
    expect(retire("s4", bound: true, pinned: false, working: true)).to eq(0)
  end
end
