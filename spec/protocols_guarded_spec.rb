require "spec_helper"
require_relative "support/stand_in_claude"
require_relative "support/protocols_kept_store"

# The crew's rules name the guard that acts on them, and each name resolves in the parsed
# bluebook: a policy that reacts, or a command with a precondition. A rule with no guard is a
# declared gap, never labelled guarded.
RSpec.describe "the crew's working agreements and the guards that hold them" do
  # Each rule, its guard, and what that guard does:
  # a hold, a priority, an advisory limit.
  RULES = {
    "a red main holds the train"    => { guard: "Pipeline:HoldEveryPushedWhenMainRed", triggers: "Passage.Hold" },
    "a red-train item goes first"   => { guard: "Tickets:PrioritizeTheRedTrainWork", triggers: "Work.Prioritize" },
    "the priority lane has a limit" => { guard: "Tickets:UnexpediteWhenExpediteRead", triggers: "Work.Unexpedite" }
  }.freeze

  # Rules the crew carries that no bluebook rule enforces today: reported, not guarded.
  UNENFORCED = ["the zero-bug rule", "a fill starts only sprint work and bugs", "the lane outranks sprint items in a fill",
                "the rules the scrum master keeps in memory"].freeze

  before(:all) { @hecks = InMemoryDomain.boot_hecks_in_memory }

  def policy_for(guard)
    domain, name = guard.split(":")
    @hecks.registry.bluebook(domain).policies.find { |found| found.name == name }
  end

  def triggered(policy) = policy.trigger_command.to_s.split("::").last(2).join(".")

  it "resolves every named guard to a policy in its bluebook", :aggregate_failures do
    RULES.each do |rule, held|
      expect(policy_for(held[:guard])).not_to be_nil, "#{rule}: no policy #{held[:guard]}"
    end
  end

  it "says what each guard acts on, not that it refuses", :aggregate_failures do
    RULES.each_value { |held| expect(triggered(policy_for(held[:guard]))).to eq(held[:triggers]) }
  end

  it "fails loudly for a guard that resolves to nothing" do
    expect(policy_for("Pipeline:HoldNothingAtAll")).to be_nil
  end

  it "keeps the unenforced rules apart from the guarded ones" do
    expect(UNENFORCED & RULES.keys).to be_empty
  end

  def enforce_accepted(reference, guard)
    Protocols::Agreement.propose!(reference: { value: reference }, text: { value: "A red main holds the train" },
                                  proposer: { value: "scrum-master" }, affects: { value: "|coder|" },
                                  touches_owner: { value: "no" }, owed: { value: 1 })
    Protocols::Agreement.find(reference).enter!(evidence: { value: "msg-1" })
    Protocols::Agreement.find(reference).enforce!(enforced_by: { value: guard })
    Protocols::Agreement.find(reference).enforced_by.value
  end

  it "enforces an accepted agreement by naming a guard that resolves" do
    root = Dir.mktmpdir("protocols-guarded")
    ProtocolsKeptStore.boot(root, Hecks::Adapters::MainIntegration::KeptRows.from_registry(@hecks.registry))
    named = enforce_accepted("WA-G1", RULES.values.first[:guard])
    FileUtils.remove_entry(root)
    expect(policy_for(named)).not_to be_nil
  end
end
