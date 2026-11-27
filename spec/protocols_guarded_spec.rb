require "spec_helper"
require_relative "support/stand_in_claude"
require_relative "support/protocols_kept_store"

# Each accepted agreement records the policy that holds it, and each recorded name resolves in the
# parsed bluebooks. An accepted agreement with no guard is a declared gap, never labelled guarded.
RSpec.describe "the crew's working agreements and the guards that hold them" do
  # The agreements entered with their guard, and the command that guard's policy triggers.
  HELD = {
    "WA-G1" => ["A red main holds the train", "Pipeline:HoldEveryPushedWhenMainRed", "Passage.Hold"],
    "WA-G2" => ["A red-train item goes first", "Tickets:PrioritizeTheRedTrainWork", "Work.Prioritize"],
    "WA-G3" => ["The priority lane has a limit", "Tickets:UnexpediteWhenExpediteRead", "Work.Unexpedite"]
  }.freeze

  # Rules the crew carries that no bluebook policy enforces today: entered, left unguarded.
  GAPS = { "WA-U1" => "The zero-bug rule", "WA-U2" => "A fill starts only sprint work and bugs",
           "WA-U3" => "The lane outranks sprint items in a fill" }.freeze

  before(:all) do
    @hecks = InMemoryDomain.boot_hecks_in_memory
    @root = Dir.mktmpdir("protocols-guarded")
    ProtocolsKeptStore.boot(@root, Hecks::Adapters::MainIntegration::KeptRows.from_registry(@hecks.registry))
    HELD.each { |ref, (text, guard)| accept(ref, text).enforce!(enforced_by: { value: guard }) }
    GAPS.each { |ref, text| accept(ref, text) }
  end

  after(:all) { FileUtils.remove_entry(@root) }

  def accept(reference, text)
    Protocols::Agreement.propose!(reference: { value: reference }, text: { value: text },
                                  proposer: { value: "scrum-master" }, affects: { value: "|coder|" },
                                  touches_owner: { value: "no" }, owed: { value: 1 })
    Protocols::Agreement.find(reference).tap { |found| found.enter!(evidence: { value: "msg-#{reference}" }) }
    Protocols::Agreement.find(reference)
  end

  def policy_for(guard)
    domain, name = guard.split(":")
    @hecks.registry.bluebook(domain).policies.find { |found| found.name == name }
  end

  def triggered(policy) = policy.trigger_command.to_s.split("::").last(2).join(".")

  def guards = Protocols::Agreement.accepted.map { |found| found[:enforced_by]&.value }.compact

  it "resolves every guard an accepted agreement records to a policy in its bluebook", :aggregate_failures do
    expect(guards.size).to eq(HELD.size)
    guards.each { |guard| expect(policy_for(guard)).not_to be_nil, "no policy #{guard}" }
  end

  it "says what each guard acts on", :aggregate_failures do
    HELD.each_value { |(_, guard, command)| expect(triggered(policy_for(guard))).to eq(command) }
  end

  it "lists the agreements no guard holds as the gap" do
    expect(Protocols::Agreement.unguarded.map { |found| found[:reference][:value] }).to match_array(GAPS.keys)
  end

  it "fails loudly for a guard that resolves to nothing" do
    expect(policy_for("Pipeline:HoldNothingAtAll")).to be_nil
  end
end
