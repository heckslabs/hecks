require "spec_helper"
require "hecks/hecks/adapters/console_capture"

# A run answers what it printed to stdout; what it printed to stderr (a domain's boot notices)
# goes on to the real stderr instead of into the answer.
RSpec.describe Hecks::Adapters::ConsoleCapture, ".answer_apart" do
  def speak
    warn "notice"
    $stdout.puts "page"
  end

  it "answers stdout alone and passes stderr on", :aggregate_failures do
    answered = nil

    expect { answered = described_class.answer_apart { speak } }.to output("notice\n").to_stderr
    expect(answered).to eq("page\n")
  end

  it "refuses with both streams when the entry point ends otherwise" do
    expect { described_class.answer_apart { speak.tap { exit(2) } } }
      .to raise_error(described_class::Failure, "page\nnotice")
  end

  it "puts both streams back afterwards", :aggregate_failures do
    streams = [$stdout, $stderr]

    described_class.answer_apart { $stdout.puts "page" }

    expect([$stdout, $stderr]).to eq(streams)
  end
end
