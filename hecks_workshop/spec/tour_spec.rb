require "spec_helper"

RSpec.describe Hecks::Workshop::Tour do
  let(:runner) { Hecks::Workshop::WorkshopRunner.new }

  before do
    runner.instance_variable_set(:@workshop, Hecks::Workshop.new("Tour"))
    allow($stdin).to receive(:tty?).and_return(false)
  end

  describe "#steps" do
    it "has 15 steps" do
      tour = described_class.new(runner)
      expect(tour.steps.size).to eq(15)
    end

    it "each step has title, explanation, code, and action" do
      tour = described_class.new(runner)
      tour.steps.each do |step|
        expect(step.title).to be_a(String)
        expect(step.explanation).to be_a(String)
        expect(step.code).to be_a(String)
        expect(step.action).to respond_to(:call)
      end
    end
  end

  describe "#start" do
    it "executes all steps without error" do
      tour = described_class.new(runner)
      output = StringIO.new
      $stdout = output
      tour.start
      $stdout = STDOUT
      text = output.string

      expect(text).to include("Hecks Workshop Tour")
      expect(text).to include("Tour complete!")
      expect(text).to include("Create an aggregate")
      expect(text).to include("play mode")
      expect(text).to include("sketch mode")
    end
  end
end
