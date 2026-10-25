# frozen_string_literal: true

require "spec_helper"
require "open3"
require "tmpdir"

# Every bluebook in the corpus is written as sentences and read back. The formatter either says it
# exactly, so the IR read back equals the IR of the Ruby form, or refuses by naming what it has no
# phrase for. It never drops anything quietly. The refusals still allowed are listed in UNSAID;
# deleting an entry is how the sentence form grows, and an entry nothing hits is itself a failure.
RSpec.describe "the sentence form against the whole corpus", :io do
  BINARY = File.expand_path("../rust/parser/target/debug/hecks-parse", __dir__)
  CORPUS = Dir[File.expand_path("../{examples,lib/hecks/framework,spec/corpus,spec/fixtures}/**/*.bluebook", __dir__)]
           .reject { |path| path.end_with?("sentence_form.bluebook") }.sort.freeze

  # What the sentence form has no phrase for yet, as the regexp its refusal matches.
  UNSAID = [
    /no phrase for the closed set/,
    /no phrase for process managers/,
    /no phrase for the options on attribute/,
    /no phrase for the paging and access options in report/,
    /no phrase for the options on (policy|query)/,
    /no phrase for a \w+ comparison in query/,
    /no phrase for that kind of mutation on command/,
    /names no aggregate/,
    /names no command \w+ declares/
  ].freeze

  def self.name_of(path) = File.read(path)[/Hecks\.bluebook\s+"([^"]+)"/, 1]

  def parse(*args)
    Open3.capture3(BINARY, *args)
  end

  # Where the Ruby form reads, its IR and its sentences; nil where hecks-parse cannot read the file.
  def sentences_of(path)
    name = self.class.name_of(path)
    ir, _, read = parse("chapter", "--chapter", name, path)
    return unless read.success?

    text, refusal, said = parse("format", "--chapter", name, path)
    { name: name, ir: ir, text: text, refusal: said.success? ? nil : refusal }
  end

  def read_back(found)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "sentences.bluebook")
      File.write(path, found[:text])
      parse("chapter", "--chapter", found[:name], path).first
    end
  end

  def outcomes
    @outcomes ||= CORPUS.filter_map { |path| [path, sentences_of(path)] if self.class.name_of(path) }
                        .select { |_, found| found }
  end

  before { skip "build rust/parser first" unless File.exist?(BINARY) }

  it "says every bluebook it accepts exactly, and loses nothing quietly", :aggregate_failures do
    outcomes.reject { |_, found| found[:refusal] }.each do |path, found|
      expect(read_back(found)).to eq(found[:ir]), "#{path} reads back differently from its sentences"
    end
  end

  it "refuses only what UNSAID lists" do
    refused = outcomes.filter_map { |path, found| "#{path}: #{found[:refusal]}" if found[:refusal] }
    unlisted = refused.reject { |line| UNSAID.any? { |said| line.match?(said) } }
    expect(unlisted).to be_empty, "refused for a reason UNSAID does not list:\n#{unlisted.join("\n")}"
  end

  it "lists no refusal that nothing hits any more" do
    refusals = outcomes.filter_map { |_, found| found[:refusal] }
    stale = UNSAID.reject { |said| refusals.any? { |line| line.match?(said) } }
    expect(stale).to be_empty, "UNSAID lists refusals no file meets any more: #{stale.map(&:inspect).join(", ")}"
  end
end
