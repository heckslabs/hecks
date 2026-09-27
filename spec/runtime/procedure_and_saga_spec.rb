require "spec_helper"

# A procedure coordinates; it is a saga when a leg also declares compensation.
# `saga` is derived from that leg and never written in a .bluebook.
RSpec.describe "a procedure, and when it is a saga" do
  def in_registry
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) do
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      yield
    end
    registry
  end

  # Coordination only: ordered steps, no undo.
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

          transition "CandidateApplied" => "screened", from: "applied" do
            dispatch Candidate::Screen, with: { candidate: :candidate }
          end
        end
      end
    end.bluebook("Hiring").process_managers.first
  end

  # Banking's settlement compensates. Booted once per file; nothing dispatches.
  before(:context) do
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      load_bluebook_files(InMemoryDomain::BANKING_BLUEBOOK_DIR)
    end
    @settlement = registry.bluebook("Banking").process_managers.find { |pm| pm.name == "Settlement" }
  end

  attr_reader :settlement

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
    # The order is the author's: one hand-written `on :refused` leg.
    expect(settlement.saga.undoes).to eq(
      ["Account.Credit", "Transfer.Reverse"]
    )
  end

  it "keeps the word out of the shared IR contract" do
    # `saga?` is a reading of the source, not a fact about it, and the IR is a shared
    # contract that must not carry derived fields.
    expect(settlement.to_h.keys).not_to include(:saga, :saga?)
  end
end
