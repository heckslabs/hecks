require "spec_helper"
require "hecks_cli"

RSpec.describe Hecks::ArchitectureTour do
  before { allow($stdin).to receive(:tty?).and_return(false) }

  describe "#steps" do
    it "has 10 steps" do
      tour = described_class.new
      expect(tour.steps.size).to eq(10)
    end

    it "each step has title, explanation, and paths" do
      tour = described_class.new
      tour.steps.each do |step|
        expect(step.title).to be_a(String)
        expect(step.explanation).to be_a(String)
        expect(step.paths).to be_an(Array)
        expect(step.paths).not_to be_empty
      end
    end
  end

  describe "#start" do
    it "prints all steps and completes" do
      tour = described_class.new
      output = StringIO.new
      $stdout = output
      tour.start
      $stdout = STDOUT
      text = output.string

      expect(text).to include("Architecture Tour")
      expect(text).to include("tour complete!")
      expect(text).to include("Monorepo layout")
      expect(text).to include("Bluebook DSL")
      expect(text).to include("Spec conventions")
    end
  end
end
