require "spec_helper"
require "tmpdir"

# A launcher word that reads its own arguments answers its usage for `--help`, `-h` and `help`
# before its handler runs: nothing is written and no state changes.
RSpec.describe Hecks::Adapters::Driving::CliRunner::WordHelp do
  let(:runtime) { Hecks.describe(File.expand_path("../../lib/hecks/hecks", __dir__), environment: nil) }
  let(:runner) { Hecks::Adapters::Driving::CliRunner }
  let(:words) { %w[tour completion resume search] }
  let(:asks) { ["--help", "-h", "help"] }

  def answer_in_tmp(*argv)
    Dir.mktmpdir do |dir|
      Dir.chdir(dir) { [runner.usage(runtime: runtime, argv: argv, program: "hecks"), Dir.children(dir)] }
    end
  end

  def every_ask = words.product(asks).map { |word, ask| answer_in_tmp(word, ask) }

  it "answers each word's usage with the answered status", :aggregate_failures do
    expect(every_ask.map { |(_, status), _| status }.uniq).to eq([0])
    expect(every_ask.map { |(text, _), _| text }).to all(start_with("usage: hecks "))
  end

  it "writes nothing in the working directory" do
    expect(every_ask.flat_map { |_, written| written }).to be_empty
  end

  it "names the word's own usage line" do
    text, = answer_in_tmp("tour", "-h").first
    expect(text).to eq("usage: hecks #{runner::TourWords::USAGE}")
  end

  it "registers each first-word handler with a one-line usage", :aggregate_failures do
    registry = runner.word_usages
    expect(registry.keys).to match_array(%w[tour search completion resume])
    expect(registry.values).to all(match(/\A\S.*\S\z/).and(satisfy { |usage| !usage.include?("\n") }))
  end

  it "answers before any handler is reached", :aggregate_failures do
    handlers = %i[tour_answer search_answer completion_answer resume]
    handlers.each { |handler| allow(runner).to receive(handler).and_raise("#{handler} reached") }
    answers = runner.word_usages.keys.product(asks).map { |word, ask| runner.word_answer({ program: "hecks" }, [word, ask]) }
    expect(answers.map { |answer| answer[:answer].last }.uniq).to eq([0])
  end

  it "does not answer help for a word it does not know" do
    text, = answer_in_tmp("nonesuch", "--help").first
    expect(text).not_to start_with("usage: hecks nonesuch")
  end

  it "still runs a tour that names a directory" do
    Dir.mktmpdir do |dir|
      Dir.chdir(dir) { runner.tour_answer({ program: "hecks", bluebook: nil }, %w[tour demo]) }
      expect(Dir.children(dir)).to eq(["demo"])
    end
  end
end
