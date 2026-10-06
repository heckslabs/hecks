require "spec_helper"
require_relative "../../../lib/hecks/hecks/adapters/console_capture"

# The shared base for Custodian adapters that wrap an entry point which prints and exits.
RSpec.describe Hecks::Adapters::ConsoleCapture do
  let(:printed) do
    described_class.capture do
      puts "one" # rubocop:disable RSpec/Output
      warn "two"
    end
  end

  it "captures what the entry point prints to stdout and stderr, in order", :aggregate_failures do
    outcome = printed

    expect(outcome.output).to eq("one\ntwo\n")
    expect(outcome).to be_ok
  end

  it "takes the exit status of an entry point that exits", :aggregate_failures do
    outcome = described_class.capture { exit 3 }

    expect(outcome.status).to eq(3)
    expect(outcome).not_to be_ok
  end

  it "captures the message of an abort", :aggregate_failures do
    outcome = described_class.capture { abort "no such thing" }

    expect(outcome.output).to eq("no such thing\n")
    expect(outcome.status).to eq(1)
  end

  it "puts the real streams back, even when the entry point raises", :aggregate_failures do
    stdout = $stdout

    expect { described_class.capture { raise "boom" } }.to raise_error("boom")
    expect($stdout).to equal(stdout)
  end

  it "answers the text of an entry point that succeeded" do
    expect(described_class.answer { puts "fine" }).to eq("fine\n") # rubocop:disable RSpec/Output
  end

  it "refuses with the text of an entry point that did not" do
    expect { described_class.answer { abort "not fine" } }
      .to raise_error(described_class::Failure, "not fine")
  end
end
