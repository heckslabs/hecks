require "spec_helper"
require "tmpdir"
require "hecks/interviews/concluded_record"

# The concluded record (ADR 0194, decision 7): an interview of Hecks's own is projected to
# `docs/interviews/<reference>.md`, each Point citing its exchange; an outside expert's is not.
module ConcludedRecordSpec
  # An interview in the shape of the Interview aggregate of the Interviews bluebook
  # (lib/hecks/interviews/interviews.bluebook, from adr0194-02-interviews-bluebook): one fixture,
  # so a renamed attribute there shows here in one place.
  def self.interview(keeping: "committed", reference: "tools-adr-2026-11-07")
    { reference: reference, subject: "Tools behind ports", keeping: keeping,
      exchanges: [{ speaker: "owner", answer: "Dissolve the tools directory." },
                  { speaker: "architect", question: "Behind ports?", answer: "Yes, few of them." }],
      points: [{ number: 1, kind: "decision", statement: "Tools go behind ports.", source: 1, status: "superseded" },
               { number: 2, kind: "decision", statement: "Few ports.", source: 2, status: "accepted", supersedes: 1 }] }
  end

  # References that are not one plain file name.
  UNSAFE = ["a/../b", "/etc/x", ".hidden", "", "a\\b", "a\u0000b"].freeze

  # @return [Array<Hash>] an outside expert's interview, and one whose keeping is missing or unknown
  def self.local_interviews
    [interview(keeping: "local"), interview.except(:keeping), interview(keeping: "Committed")]
  end

  # @param reference [String] an interview reference
  # @return [ArgumentError, nil] what projecting the path of an interview with this reference raised
  def self.refusal(reference)
    Hecks::Interviews::ConcludedRecord.path(root: "/checkout", interview: interview(reference: reference))
    nil
  rescue ArgumentError => e
    e
  end
end

RSpec.describe Hecks::Interviews::ConcludedRecord do
  let(:root) { Dir.mktmpdir("concluded-record") }
  let(:interview) { ConcludedRecordSpec.interview }
  let(:files) { described_class.files(root: root, interview: interview) }
  let(:record) { files.fetch(File.join(root, "docs", "interviews", "tools-adr-2026-11-07.md")) }

  after { FileUtils.rm_rf(root) }

  it "answers the record of a Hecks interview at docs/interviews/<reference>.md, writing nothing", :aggregate_failures do
    expect(files.keys).to eq([File.join(root, "docs/interviews/tools-adr-2026-11-07.md")])
    expect(Dir.exist?(File.join(root, "docs"))).to be(false)
  end

  it "cites each Point's exchange by a link to that exchange's heading", :aggregate_failures do
    expect(record).to include("- Point 1, decision, superseded, citing [exchange 1](#exchange-1): Tools go behind ports.")
    expect(record).to include("citing [exchange 2](#exchange-2): Few ports. Supersedes point 1.")
  end

  it "has a heading for each exchange a Point cites, so the link resolves" do
    headings = record.scan(/^### (Exchange \d+)$/).flatten.map { |heading| heading.downcase.tr(" ", "-") }
    expect(record.scan(/\]\(#(exchange-\d+)\)/).flatten.uniq).to eq(headings)
  end

  it "keeps every exchange in the speaker's words, with its question", :aggregate_failures do
    expect(record).to include("### Exchange 1\n\n**owner:** Dissolve the tools directory.")
    expect(record).to include("### Exchange 2\n\n**Question:** Behind ports?\n\n**architect:** Yes, few of them.")
  end

  it "has no record for an outside expert's interview, nor one whose keeping is missing or unknown" do
    records = ConcludedRecordSpec.local_interviews.map { |local| described_class.files(root: root, interview: local) }
    expect(records).to all(eq({}))
  end

  it "refuses a reference that is not one plain file name" do
    refusals = ConcludedRecordSpec::UNSAFE.map { |reference| ConcludedRecordSpec.refusal(reference)&.message }
    expect(refusals).to all(include("one plain file name"))
  end
end
