require "spec_helper"
require "hecks/hecks/adapters/work_areas"

# A work item starts on a section of a bluebook that another started item does not hold.
RSpec.describe Hecks::Adapters::WorkAreas, "#check_area" do
  let(:areas) { described_class.new }

  before do
    other = { key: "adds-brief", area: ["lib/x/x.bluebook#Brief"] }
    allow(Hecks::Adapters::StartedWork).to receive(:items).and_return([other])
  end

  it "starts a work item on another section of a bluebook a started one holds" do
    said = areas.check_area(work: "adds-coder", area: ["lib/x/x.bluebook#Coder"])
    expect(said.dig(:output, :value)).to eq("adds-coder holds lib/x/x.bluebook#Coder")
  end

  it "refuses a work item that claims the section a started one holds" do
    expect { areas.check_area(work: "adds-coder", area: ["lib/x/x.bluebook#Brief"]) }
      .to raise_error(Hecks::Adapters::ConsoleCapture::Failure, %r{adds-brief holds lib/x/x\.bluebook#Brief})
  end
end
