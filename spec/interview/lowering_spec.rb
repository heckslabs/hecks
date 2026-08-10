require "spec_helper"
require "hecksagain/interview"

RSpec.describe Hecksagain::Interview::Lowering do
  subject(:lowering) { described_class.new }

  def row(name, field, value) = { name: name, field: field, value: value }

  describe "#lower" do
    it "passes a bare argument (empty field) straight through as a plain string" do
      verb, args = lowering.lower("Bluebook::Aggregate.Declare",
                                   [row("bluebook_id", "", "Loyalty"), row("name", "value", "Member")])

      expect(verb).to eq("Bluebook::Aggregate.Declare")
      expect(args).to eq(bluebook_id: "Loyalty", name: { value: "Member" })
    end

    it "addresses by :id alone without colliding with a same-named payload field — " \
       "Aggregate.Attribute declares its OWN 'name' argument, which would collide with " \
       "the identity head of the same name if addressed any other way" do
      _verb, args = lowering.lower("Bluebook::Aggregate.Attribute",
                                    [row("id", "", "Loyalty:Member"),
                                     row("type", "", "Loyalty:Member:Points"),
                                     row("name", "value", "points"),
                                     row("list", "value", "false")])

      expect(args[:id]).to eq("Loyalty:Member")
      expect(args[:name]).to eq(value: "points")
    end

    it "coerces a value into a real Integer when the language's own IR says the field " \
       "is Integer-typed — proven load-bearing, not just shaped right: RowCount.value " \
       "genuinely refuses a bare string and accepts the coerced value" do
      _verb, args = lowering.lower("Bluebook::ValueObject.Close",
                                    [row("id", "", "Loyalty:Member:Points"), row("rows", "value", "3")])

      expect(args[:rows]).to eq(value: 3)
      expect(args[:rows][:value]).to be_an(Integer)

      session = Hecksagain::Interview::Session.open("Loyalty")
      session.offer("Bluebook::Aggregate.Declare", bluebook_id: "Loyalty", name: { value: "Member" })
      session.offer("Bluebook::ValueObject.Declare", aggregate_id: "Loyalty:Member", name: { value: "Points" })

      raw_string = session.offer("Bluebook::ValueObject.Close", id: "Loyalty:Member:Points", rows: { value: "3" })
      expect(raw_string).not_to be_accepted # the fact the coercion exists to prevent

      coerced = session.offer("Bluebook::ValueObject.Close", id: "Loyalty:Member:Points", rows: { value: 3 })
      expect(coerced).to be_accepted
    end

    it "leaves a String-typed field as text — the meta-language's own flags " \
       "(ListFlag { value: String }) are text, not a Ruby TrueClass/FalseClass, " \
       "and Reconstruction is what turns \"false\" back into a boolean, on read" do
      _verb, args = lowering.lower("Bluebook::Aggregate.Attribute",
                                    [row("id", "", "Loyalty:Member"), row("type", "", "Loyalty:Member:Points"),
                                     row("name", "value", "points"), row("list", "value", "false")])

      expect(args[:list]).to eq(value: "false")
    end

    it "raises MalformedProposal for a category the language does not declare" do
      expect { lowering.lower("Bluebook::Nonsense.Declare", []) }
        .to raise_error(described_class::MalformedProposal, /Nonsense/)
    end

    it "raises MalformedProposal for a verb the category does not declare" do
      expect { lowering.lower("Bluebook::Aggregate.Frobnicate", []) }
        .to raise_error(described_class::MalformedProposal, /Frobnicate/)
    end

    it "raises MalformedProposal when a proposal mixes a bare value with fielded ones " \
       "under the same argument name — a proposal-composition defect, not a domain refusal" do
      expect do
        lowering.lower("Bluebook::Aggregate.Attribute",
                        [row("name", "", "bare"), row("name", "value", "fielded")])
      end.to raise_error(described_class::MalformedProposal, /mixes a bare value/)
    end
  end

  describe "#lower_proposal" do
    def boot_interview
      registry = Hecksagain::Runtime::Registry.new
      Hecksagain.with_registry(registry) do
        Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
        Kernel.load(InMemoryDomain::EXTRACTION_PORT)
        Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
        Kernel.load(InMemoryDomain::PRISM_ADAPTER)
        Kernel.load(File.join(InMemoryDomain::ROOT, "lib/hecksagain/framework/bluebook/interview.bluebook"))
        Hecks.hecksagon("Interview") do
          ::Interview::Interview.persisted_by("Memory")
          ::Interview::StandingQuestion.persisted_by("Memory")
          ::Interview::Finding.persisted_by("Memory")
          ::Interview::Proposal.persisted_by("Memory")
        end
      end
      registry.verify!
      Hecksagain::Runtime::Loader.bind_runtime(Hecksagain::Runtime::Dispatcher.new(registry))
    end

    it "lowers a REAL Proposal record — read through the door, arguments as Runtime::Value, " \
       "not a hand-built hash — into the exact same dispatch #lower produces from plain rows" do
      boot_interview
      Interview::Interview.open(session: { value: "s1" }, subject: { value: "x" },
                                 chapter: { value: "Loyalty" }, respondent: { value: "id-1" })
      Interview::Finding.establish(interview_id: "s1", reference: { value: "f1" }, sequence: { value: 1 },
                                    topic: { value: "t" }, statement: { value: "stmt" })
      proposal = Interview::Proposal.propose(interview_id: "s1", finding_id: "f1", reference: { value: "p1" },
                                              sequence: { value: 1 }, verb: { value: "Bluebook::Aggregate.Attribute" },
                                              rationale: { value: "r" })
      proposal = proposal.supply(name: { value: "id" }, field: { value: "" }, value: { value: "Loyalty:Member" })
      proposal = proposal.supply(name: { value: "type" }, field: { value: "" },
                                  value: { value: "Loyalty:Member:Points" })
      proposal = proposal.supply(name: { value: "name" }, field: { value: "value" }, value: { value: "points" })

      verb, args = lowering.lower_proposal(proposal)

      expect(verb).to eq("Bluebook::Aggregate.Attribute")
      expect(args).to eq(id: "Loyalty:Member", type: "Loyalty:Member:Points", name: { value: "points" })
    end
  end
end
