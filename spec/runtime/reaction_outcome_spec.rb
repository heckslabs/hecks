require "spec_helper"

RSpec.describe Hecks::Runtime::ReactionOutcome do
  let(:accept_refused) do
    { policy: "AcceptTheRelease", on: "Released", trigger: "Deploy::Release.Accept",
      delivered: false, reason: "the working tree is dirty" }
  end
  let(:note_delivered) do
    { policy: "NoteTheRelease", on: "Released", trigger: "Deploy::Release.Note", delivered: true }
  end
  let(:first_event)  { "uid-1" }
  let(:second_event) { "uid-2" }

  def blocked(entries, events = {})
    described_class.blocking(entries, event_of: ->(entry) { events[entry] }).map { |row| row[:trigger] }
  end

  it "passes a refusal whose sibling policy answered the same event instance with another command" do
    expect(blocked([accept_refused, note_delivered],
                   accept_refused => first_event, note_delivered => first_event)).to eq([])
  end

  it "blocks a refusal when the sibling policy answered a different event of the same name" do
    expect(blocked([accept_refused, note_delivered],
                   accept_refused => first_event, note_delivered => second_event))
      .to eq(["Deploy::Release.Accept"])
  end

  it "matches on the event name alone when the log carries no event identity" do
    expect(blocked([accept_refused, note_delivered])).to eq([])
  end

  it "reads the event a registry logged each reaction with, leaving the record's own keys alone" do
    registry = Hecks::Runtime::Registry.new
    registry.log_reaction(accept_refused, event: first_event)
    registry.log_reaction(note_delivered, event: second_event)

    expect(registry.reaction_log.first.keys).to eq(%i[policy on trigger delivered reason])
    expect(described_class.blocking(registry.reaction_log, event_of: registry.method(:reaction_event)).size).to eq(1)
    registry.reset_runtime_state!
    expect(registry.reaction_event(accept_refused)).to be_nil
  end

  describe "a creating command reporting the record already exists" do
    let(:register) do
      { policy: "RegisterIt", on: "Provisioned", trigger: "Tenancy::Tenant.Register", delivered: false,
        reason: "Register creates a Tenant that already exists — slug.value \"a\"" }
    end

    it "is benign when the sentence is the triggered command's own" do
      expect(blocked([register])).to eq([])
    end

    it "blocks when the sentence names a different command than the one triggered" do
      expect(blocked([register.merge(trigger: "Tenancy::Tenant.Rename")])).to eq(["Tenancy::Tenant.Rename"])
    end

    it "blocks a refusal that merely reads like the template around another aggregate" do
      expect(blocked([register.merge(reason: "Register creates a Site that already exists — x")]))
        .to eq(["Tenancy::Tenant.Register"])
    end
  end
end
