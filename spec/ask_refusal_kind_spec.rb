require "spec_helper"

# An adapter that refuses an ask names the kind of its refusal on the error, and the refusal event
# carries it beside the sentence, so a policy tells a red gate from a conflict without reading
# the text (Hecks ADR 0208). An error that names none refuses as it always did.
RSpec.describe "an ask's refusal, with its kind" do
  # A refusal an adapter raises with the kind it names.
  let(:refused) do
    Class.new(Hecks::Adapters::ConsoleCapture::Failure) do
      def kind = "gate_red"
    end
  end

  describe Hecks::Runtime, ".refusal_kind" do
    it "is the kind the error names" do
      expect(described_class.refusal_kind(refused.new("the gate is red"))).to eq("gate_red")
    end

    it "is nothing for an error that names none" do
      expect(described_class.refusal_kind(RuntimeError.new("it failed"))).to be_nil
    end

    it "is nothing for a kind that is blank" do
      blank = Class.new(RuntimeError) { def kind = "  " }
      expect(described_class.refusal_kind(blank.new("it failed"))).to be_nil
    end
  end
end
