require "spec_helper"
require "hecks/hecks/adapters/git_train"
require "hecks/hecks/adapters/push_recorder"
require "hecks/hecks/adapters/git_launcher"
require "hecks/hecks/adapters/desktop_alert"

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

  describe "announced by the booted Hecks domain" do
    before(:all) { @hecks = boot_hecks_in_memory }

    let(:train) { instance_double(Hecks::Adapters::GitTrain) }

    before do
      allow(Hecks::Adapters::GitTrain).to receive(:new).and_return(train)
      allow(Hecks::Adapters::PushRecorder).to receive(:new)
        .and_return(instance_double(Hecks::Adapters::PushRecorder, record_outcome: { report: { value: "recorded" } }))
      allow(Hecks::Adapters::GitLauncher).to receive(:new)
        .and_return(instance_double(Hecks::Adapters::GitLauncher, refresh: { report: { value: "left" } }))
      allow(Hecks::Adapters::DesktopAlert).to receive(:new)
        .and_return(instance_double(Hecks::Adapters::DesktopAlert, announce: { report: { value: "shown" } }))
    end

    def board(run)
      @hecks.dispatch_flat("Hecks::SendTrain.Board", run: { value: run }, checkout: { value: "/checkout" },
                                                     confirm: { value: true })
    end

    def kinds = @hecks.registry.event_log.to_a.filter_map { |event| event.payload[:kind] }

    it "puts the kind beside the sentence on the refusal event" do
      allow(train).to receive(:carry).and_raise(refused, "the gate is red")
      board("kind-named")
      expect(kinds.last).to eq(value: "gate_red")
    end

    it "adds no kind to the refusal of an error that names none" do
      before = kinds.size
      allow(train).to receive(:carry).and_raise(Hecks::Adapters::ConsoleCapture::Failure, "plain")
      board("kind-unnamed")
      expect(kinds.size).to eq(before)
    end
  end
end
