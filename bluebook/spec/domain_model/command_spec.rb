require "spec_helper"

RSpec.describe Hecks::DomainModel::Behavior::Command do
  subject(:command) do
    described_class.new(name: "CreatePizza", attributes: [])
  end

  describe "#inferred_event_name" do
    it "converts Create to Created" do
      cmd = described_class.new(name: "CreatePizza", attributes: [])
      expect(cmd.inferred_event_name).to eq("CreatedPizza")
    end

    it "converts Add to Added" do
      cmd = described_class.new(name: "AddTopping", attributes: [])
      expect(cmd.inferred_event_name).to eq("AddedTopping")
    end

    it "converts Place to Placed" do
      cmd = described_class.new(name: "PlaceOrder", attributes: [])
      expect(cmd.inferred_event_name).to eq("PlacedOrder")
    end

    context "CVC doubling via DOUBLE_FINAL" do
      it "doubles final consonant for Submit" do
        cmd = described_class.new(name: "SubmitOrder", attributes: [])
        expect(cmd.inferred_event_name).to eq("SubmittedOrder")
      end

      it "doubles final consonant for Refer" do
        cmd = described_class.new(name: "ReferFriend", attributes: [])
        expect(cmd.inferred_event_name).to eq("ReferredFriend")
      end
    end

    context "CVC doubling via monosyllable regex fallback" do
      it "doubles final consonant for Drop" do
        cmd = described_class.new(name: "DropItem", attributes: [])
        expect(cmd.inferred_event_name).to eq("DroppedItem")
      end

      it "doubles final consonant for Plan" do
        cmd = described_class.new(name: "PlanTrip", attributes: [])
        expect(cmd.inferred_event_name).to eq("PlannedTrip")
      end
    end

    context "multi-syllable stress-final doubling" do
      it "doubles final consonant for Overlap" do
        cmd = described_class.new(name: "OverlapShift", attributes: [])
        expect(cmd.inferred_event_name).to eq("OverlappedShift")
      end

      it "doubles final consonant for Unwrap" do
        cmd = described_class.new(name: "UnwrapGift", attributes: [])
        expect(cmd.inferred_event_name).to eq("UnwrappedGift")
      end
    end

    context "irregular verbs" do
      it "converts Forget to Forgot" do
        cmd = described_class.new(name: "ForgetPassword", attributes: [])
        expect(cmd.inferred_event_name).to eq("ForgotPassword")
      end

      it "converts Upset to Upset" do
        cmd = described_class.new(name: "UpsetBalance", attributes: [])
        expect(cmd.inferred_event_name).to eq("UpsetBalance")
      end

      it "converts Broadcast to Broadcast" do
        cmd = described_class.new(name: "BroadcastMessage", attributes: [])
        expect(cmd.inferred_event_name).to eq("BroadcastMessage")
      end
    end

    context "consonant-y rule" do
      it "converts Deny to Denied" do
        cmd = described_class.new(name: "DenyAccess", attributes: [])
        expect(cmd.inferred_event_name).to eq("DeniedAccess")
      end
    end
  end

  describe "#event_names" do
    context "when emits is nil (default)" do
      it "returns array with inferred event name" do
        cmd = described_class.new(name: "CreatePizza", attributes: [])
        expect(cmd.event_names).to eq(["CreatedPizza"])
      end
    end

    context "when emits is a single string" do
      it "returns array with that name" do
        cmd = described_class.new(name: "CreatePizza", attributes: [], emits: "PizzaCreated")
        expect(cmd.event_names).to eq(["PizzaCreated"])
      end
    end

    context "when emits is an array of names" do
      it "returns all names" do
        cmd = described_class.new(name: "CreatePizza", attributes: [], emits: ["PizzaCreated", "MenuUpdated"])
        expect(cmd.event_names).to eq(["PizzaCreated", "MenuUpdated"])
      end
    end
  end

  describe "#emits" do
    it "is nil by default" do
      cmd = described_class.new(name: "CreatePizza", attributes: [])
      expect(cmd.emits).to be_nil
    end

    it "stores a single name string" do
      cmd = described_class.new(name: "CreatePizza", attributes: [], emits: "PizzaCreated")
      expect(cmd.emits).to eq("PizzaCreated")
    end

    it "stores an array for multiple names" do
      cmd = described_class.new(name: "CreatePizza", attributes: [], emits: ["PizzaCreated", "MenuUpdated"])
      expect(cmd.emits).to eq(["PizzaCreated", "MenuUpdated"])
    end
  end
end
