
require "spec_helper"

# A PROCEDURE coordinates. It is a SAGA when it also knows how to undo itself.
#
# These are two things and the industry slurs them into one word. A procedure has
# legs, states, and an opinion about who goes next. A saga has compensation: every
# step that changed the world declares what makes it good again, and a failure
# runs those backwards. Neither implies the other — a hiring pipeline is ordered
# and has no undo, a choreographed refund has undo and nobody in charge.
#
# The word `saga` appears in no .bluebook and never will: it is not a word a bank
# says, and an author never types it. They declare a compensating leg, and the
# saga-ness FOLLOWS. So the name is derived rather than declared, which is also
# why it cannot drift from the thing it describes.
RSpec.describe "a procedure, and when it is a saga" do
  def in_registry
    registry = Hecksagain::Runtime::Registry.new
    Hecks.with_registry(registry) do
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      yield
    end
    registry
  end

  # Coordination only. Steps in order, no undo — you cannot un-interview anybody.
  def hiring
    in_registry do
      Hecks.bluebook("Hiring") do
        vision "Carry a candidate from application to offer."
        supporting

        aggregate "Candidate" do
          identified_by :id
          description "Somebody applying for a job."

          attribute :stage, Stage

          value_object "Stage" do
            attribute :value, String
            invariant("a stage is named") { !value.to_s.empty? }
          end

          command "Screen" do
            role "Recruiter"
            goal "Read the application"
            reference_to Candidate
            attribute :stage, Stage
            sets :stage
            emits "CandidateScreened"
          end
        end

        process_manager "Pipeline" do
          correlates_by :"candidate.id"
          starts_on "CandidateApplied"
          ends_on   "OfferAccepted"

          state "applied"
          state "screened"

          on "CandidateApplied", transition: { "applied" => "screened" } do
            dispatch Candidate::Screen, with: { candidate: :candidate }
          end
        end
      end
    end.bluebook("Hiring").process_managers.first
  end

  # Banking's settlement, which compensates — money out of one account has to come
  # back if the other will not take it. Booted ONCE per file — nothing below
  # ever dispatches, only reads the loaded process manager's IR back out.
  before(:context) do
    registry = Hecksagain::Runtime::Registry.new
    Hecksagain.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      Kernel.load(File.join(InMemoryDomain::ROOT, "examples/banking/bluebook/banking.bluebook"))
    end
    @settlement = registry.bluebook("Banking").process_managers.find { |pm| pm.name == "Settlement" }
  end

  def settlement = @settlement

  it "is a procedure without being a saga, when nothing needs undoing" do
    expect(hiring.handlers).not_to be_empty
    expect(hiring).not_to be_saga
    expect(hiring.saga).to be_nil
  end

  it "is a saga once a leg says what makes a refusal good again" do
    expect(settlement).to be_saga
    expect(settlement.saga.to_state).to eq("reversed")
    expect(settlement.saga.trigger).to eq("refused")
  end

  it "names what the saga undoes, in the order it undoes it" do
    # Today the order is the AUTHOR's — one `on :refused` leg, written by hand.
    # When compensation moves beside each dispatch this reads the completed legs
    # newest-first instead, and the shape here does not change.
    expect(settlement.saga.undoes).to eq(
      ["Account.Credit", "Transfer.Reverse"]
    )
  end

  it "keeps the word out of the shared IR contract" do
    # `saga?` is DERIVED. Putting it in to_h would make it a fact about the source
    # that every reader of the IR would then have to carry — and it is not a fact
    # about the source, it is a reading of it. The IR is a shared contract; adding
    # a derived field to it has split contract from source twice already in this
    # project's history.
    expect(settlement.to_h.keys).not_to include(:saga, :saga?)
  end
end
