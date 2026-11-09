require "spec_helper"
require "hecks/hecks/adapters/dispatching"

# A coder is briefed with the known traps its area meets, and a red cause is matched to its kind by
# the text CI printed. Both read the lessons they are given and touch no store.
RSpec.describe "the known traps a coder is briefed with" do
  describe Hecks::Adapters::Dispatching::LessonTraps do
    let(:coder) do
      { kind: "coder-kind", signature: ["spec/coder_spec.rb"], cause: "c", check: "run the coder spec",
        fix: "fix the coder", always: "no", area: ["lib/hecks/coder"] }
    end
    let(:spec_kind) do
      { kind: "spec-kind", signature: ["uninitialized constant"], cause: "c", check: "run it in a shard",
        fix: "require the constant", always: "no", area: ["spec"] }
    end
    let(:always_kind) do
      { kind: "always-kind", signature: ["Co-Authored-By"], cause: "c", check: "check the range",
        fix: "amend the message", always: "yes", area: [] }
    end
    let(:lessons) { [coder, spec_kind, always_kind] }

    it "briefs the lessons whose area overlaps the work item's area", :aggregate_failures do
      traps = described_class.new(lessons).for(["lib/hecks/coder/brief"])
      expect(traps.join).to include("coder-kind", "fix the coder")
      expect(traps.join).not_to include("spec-kind")
    end

    it "briefs every lesson marked always, whatever the area" do
      expect(described_class.new(lessons).for(["lib/hecks/other"]).join).to include("always-kind")
    end

    it "briefs only the always lessons to a work item with no area" do
      traps = described_class.new(lessons).for([])
      expect(traps.map { |line| line.split(":").first }).to eq(["always-kind"])
    end

    it "matches a red cause to the kind whose signature its CI text names" do
      expect(described_class.match(lessons, "FAILED spec/coder_spec.rb:12")).to eq(["coder-kind"])
    end

    it "reports no kind for a red cause that no signature names: a gap for the coordinator" do
      expect(described_class.match(lessons, "NoMethodError in spec/brand_new_spec.rb")).to be_empty
    end
  end

  describe Hecks::Adapters::Dispatching::BriefText do
    let(:brief) { { "outcome" => "Retire the old route", "rules" => "Map the picture." } }

    it "heads the known traps in the brief" do
      text = described_class.new(brief).render("work/x", traps: ["coder-kind: fix: fix the coder Check: run it."])
      expect(text).to include("Known traps:\n- coder-kind: fix: fix the coder Check: run it.")
    end

    it "fills {main} with the primary checkout, and names the worktree's key in {work}", :aggregate_failures do
      brief["review"] = "{main}/exe/hecks agents PlanReview.reviews for {work}"
      expect(described_class.new(brief).render("work/x", main: "/repo/")).to include(
        "/repo/exe/hecks agents PlanReview.reviews for work/x"
      )
    end

    it "refuses to write a brief that names {main} when no main checkout was given" do
      brief["review"] = "{main}/exe/hecks agents PlanReview.reviews"
      expect { described_class.new(brief).render("work/x") }.to raise_error(ArgumentError, /\{main\}/)
    end

    it "leaves the known-traps heading out when no lesson meets the area" do
      expect(described_class.new(brief).render("work/x", traps: [])).not_to include("Known traps")
    end
  end
end
