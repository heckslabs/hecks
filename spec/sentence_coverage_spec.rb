# frozen_string_literal: true

require "spec_helper"
require "open3"
require "tmpdir"

# Every bluebook in the corpus is written as sentences and read back. The formatter either says it
# exactly, so the IR read back equals the IR of the Ruby form, or refuses by naming what it has no
# phrase for. It never drops anything quietly. The refusals still allowed are listed in
# SENTENCE_UNSAID; deleting an entry is how the sentence form grows, and an entry nothing hits is
# itself a failure.
RSpec.describe "the sentence form against the whole corpus", :io do
  SENTENCE_BINARY = File.expand_path("../rust/parser/target/debug/hecks-parse", __dir__)
  SENTENCE_GLOB = File.expand_path("../{examples,lib/hecks/framework,spec/corpus,spec/fixtures}/**/*.bluebook", __dir__)
  SENTENCE_FILES = Dir[SENTENCE_GLOB].reject { |path| path.end_with?("sentence_form.bluebook") }.freeze

  # What the sentence form still refuses. The first two are bluebooks that are incoherent on purpose
  # (a policy triggering a command nobody declares, a transition naming a command nobody declares)
  # or that reach into another bluebook, which a standalone sentence file cannot say; the last is a
  # report that pages each of several included aggregates on its own. The next is Governance's live
  # queries, which filter on `ends_at: nil`: the sentence form has no "is not set" phrase for a
  # filter yet, and adding one is a Rust parser change (ADR 0140).
  SENTENCE_UNSAID = [
    /triggers \S+, a command this bluebook does not declare/,
    /names no command \w+ declares/,
    /no phrase for this filter in query Live\w+/,
    /no phrase for this paging option in report/
  ].freeze

  def self.name_of(path) = File.read(path)[/Hecks\.bluebook\s+"([^"]+)"/, 1]

  # A bluebook is the files of one directory that declare the same name, read together as the
  # loader reads them.
  def self.declarations
    grouped = SENTENCE_FILES.group_by { |path| [File.dirname(path), name_of(path)] }
    grouped.reject { |(_, name), _| name.nil? }.freeze
  end

  SENTENCE_BLUEBOOKS = declarations

  def parse(*args)
    Open3.capture3(SENTENCE_BINARY, *args)
  end

  # Where the Ruby form reads, its IR and its sentences; nil where hecks-parse cannot read it.
  def sentences_of(name, paths)
    ir, _, read = parse("bluebook", "--bluebook", name, *paths)
    return unless read.success?

    text, refusal, said = parse("format", "--bluebook", name, *paths)
    { name: name, ir: ir, text: text, refusal: said.success? ? nil : refusal }
  end

  def read_back(found)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "sentences.bluebook")
      File.write(path, found[:text])
      parse("bluebook", "--bluebook", found[:name], path).first
    end
  end

  def outcomes
    @outcomes ||= SENTENCE_BLUEBOOKS.filter_map do |(dir, name), paths|
      found = sentences_of(name, paths)
      ["#{dir}/#{name}", found] if found
    end
  end

  def refusals = outcomes.filter_map { |_, found| found[:refusal] }

  before { skip "build rust/parser first" unless File.exist?(SENTENCE_BINARY) }

  it "says every bluebook it accepts exactly, and loses nothing quietly", :aggregate_failures do
    outcomes.reject { |_, found| found[:refusal] }.each do |path, found|
      expect(read_back(found)).to eq(found[:ir]), "#{path} reads back differently from its sentences"
    end
  end

  it "refuses only what SENTENCE_UNSAID lists" do
    unlisted = refusals.reject { |line| SENTENCE_UNSAID.any? { |said| line.match?(said) } }

    expect(unlisted).to be_empty, "refused for a reason SENTENCE_UNSAID does not list:\n#{unlisted.join("\n")}"
  end

  it "lists no refusal that nothing hits any more" do
    stale = SENTENCE_UNSAID.reject { |said| refusals.any? { |line| line.match?(said) } }

    expect(stale).to be_empty, "SENTENCE_UNSAID lists refusals nothing meets any more: #{stale.map(&:inspect).join(", ")}"
  end
end
