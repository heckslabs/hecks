require "spec_helper"
require "json"
require "hecks/hecks/adapters/main_integration/train"

# What a boarding reads from the push train's answer. A record that parses is the train's state; a
# record that will not parse is refused with its text, so the train's reason for refusing is never
# lost behind an empty state. The runner stands in for the train, so nothing is boarded.
RSpec.describe Hecks::Adapters::MainIntegration::Train do
  let(:failure) { Hecks::Adapters::ConsoleCapture::Failure }

  def board_answering(passed, output) = described_class.new(->(_argv, **) { [passed, output] }, root: "/train").board("/co")

  it "answers the state of a record the remote holds" do
    record = JSON.generate(state: { status: "pushed" })
    expect(board_answering(true, "boarding\n#{record}\n")).to eq("status" => "pushed")
  end

  it "refuses with the train's refusal when it parses" do
    record = JSON.generate(state: { status: "refused", refusal: "main is red: flag 7" })
    expect { board_answering(false, record) }.to raise_error(failure, /main is red: flag 7/)
  end

  it "refuses a record that will not parse with the record's own text, refusal included" do
    broken = %({"state": {"status": "refused", "refusal": "main is red: flag 7"})
    expect { board_answering(false, broken) }.to raise_error(failure, /could not be read.*main is red: flag 7/)
  end

  it "keeps only the tail of a long record that will not parse" do
    broken = %({"state": {"note": "#{"x" * 2000}", "refusal": "board again"})
    expect { board_answering(false, broken) }.to raise_error(failure, /\A.{0,500}\z/m)
  end
end
