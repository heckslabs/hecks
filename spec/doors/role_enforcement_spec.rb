require "spec_helper"
require_relative "../support/doors"

# Every role-gated command of every example domain refuses a caller of another role, at every
# door that takes a role: Ruby, and MCP for the chapter it serves. Its args are synthesized, so
# a command whose synthesized args are refused before the role gate proves nothing; those are
# listed in `UNGATED_BY_SYNTHESIS`, and the list must stay exact.
RSpec.describe "every role-gated command, at every door that takes a role", :aggregate_failures do
  # Commands whose synthesized args fail a pattern or closed set before the role gate is reached.
  UNGATED_BY_SYNTHESIS = %w[
    Banking::Customer.Register Banking::Account.Credit Banking::Account.Debit Banking::Account.ApplyFee
    Banking::Account.CorrectFee Banking::Account.AccrueInterest Banking::Account.CorrectInterest
    Banking::ExternalTransfer.Request Banking::Hold.Place Bulk::BulkRun.Record
  ].freeze

  def self.domains = Hecks::Corpus.members(:example).map(&:path).sort

  # `[verb, ruby outcome, mcp outcome or nil]` for each role-gated command of one domain.
  def self.gate_outcomes(dir)
    Hecks::Fuzzing::IsolatedBoot.call(dir) do |copy|
      runtime = Hecks.boot(copy, environment: nil)
      Doors.intruder_steps(runtime).map do |step|
        mcp = step["verb"].start_with?("#{Doors.mcp_chapter(runtime)}::") ? Doors.call(:mcp, runtime, step) : nil
        [step["verb"], Doors.call(:ruby, runtime, step), mcp]
      end
    end
  end

  def self.outcomes = @outcomes ||= domains.to_h { |dir| [File.basename(dir), gate_outcomes(dir)] }

  def self.ungated = outcomes.values.flatten(1).reject { |_, ruby, _| ruby.last.to_s.end_with?("Unauthorized") }

  domains.map { |dir| File.basename(dir) }.each do |name|
    it "refuses #{name}'s role-gated commands as Unauthorized through Ruby, unless listed" do
      expect(self.class.outcomes[name].reject { |verb, ruby, _| gated?(verb, ruby) }).to be_empty
    end

    it "answers #{name}'s role-gated commands through MCP exactly as through Ruby" do
      differing = self.class.outcomes[name].select { |_, ruby, mcp| mcp && mcp != ruby[0..1] }
      expect(differing).to be_empty
    end
  end

  def gated?(verb, ruby) = ruby.last.to_s.end_with?("Unauthorized") || UNGATED_BY_SYNTHESIS.include?(verb)

  it "lists as ungated by synthesis exactly the commands whose args are refused first" do
    expect(self.class.ungated.map(&:first)).to match_array(UNGATED_BY_SYNTHESIS)
  end

  it "never accepts a role-gated command from a caller of another role" do
    expect(self.class.ungated.map { |_, ruby, _| ruby.first }.uniq).to eq([:refused])
  end

  # A role-gated command dispatched with no caller at all: MCP refuses it, while the Ruby API,
  # an in-process caller, checks a role only once one is bound. Pinned so a change to either
  # side is a decision, not a drift.
  it "refuses a role-gated command with no role through MCP, and runs it through Ruby with no caller bound" do
    expect(Doors::ROLE_DOORS.to_h { |door| [door, bare_open(door)] }).to eq(ruby: :ok, mcp: :refused)
  end

  # The outcome of opening a fixture box through `door` with no role stated.
  def bare_open(door)
    step = { "verb" => "RefusalKinds::Box.Open", "args" => { "number" => { "value" => "b9" } } }
    Hecks::Fuzzing::IsolatedBoot.call(File.join(InMemoryDomain::ROOT, "spec/fixtures/refusal_kinds")) do |copy|
      Doors.call(door, Hecks.boot(copy, environment: nil), step).first
    end
  end

  it "refuses a role-gated command from a caller of another role through the Rust host",
     :io, pending: "rust/host submit paths dispatch with role None (api.rs:384, api.rs:444, web.rs:2014; " \
                   "host security review 2026-10-22, open HIGH finding), and no spec harness drives the host yet" do
    raise NotImplementedError, "no in-process seam drives rust/host; see the pending reason"
  end
end
