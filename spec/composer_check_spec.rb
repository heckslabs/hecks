require "spec_helper"
require "hecks/composer"
require_relative "support/hecks_parse_binary"

# The Composer's check judges a workspace as it stands on screen: the files on disk with unsaved
# text laid over them. It runs the Rust parser, so the group builds it and runs where it can.
RSpec.describe Hecks::Composer::Check, :io do
  include_context "with the hecks-parse binary"

  let(:dir)  { File.expand_path("fixtures/composer/account", __dir__) }
  let(:file) { "ledger.bluebook" }

  def source = File.read(File.join(dir, file))

  def check(text = nil) = described_class.call(dir: dir, buffers: text ? { file => text } : {})

  def misspelt = source.sub("sets :balance", "sett :balance")

  def with_unperformed_step
    source.sub('transition "FreezeAccount" => "frozen", from: "open"',
               %(transition "FreezeAccount" => "frozen", from: "open"\n      transition "Close" => "closed", from: "open"))
  end

  it "reads a clean workspace without a refusal", :aggregate_failures do
    result = check

    expect(result[:diagnostic]).to be_nil
    expect(result[:chapter]).to eq("Ledger")
    expect(result[:elapsed_ms]).to be_a(Integer)
  end

  it "draws the diagrams and reads back the statements", :aggregate_failures do
    result = check

    expect(result[:diagrams].keys).to include("Account_lifecycle.mmd")
    expect(result[:statements]).to include(a_string_matching(/account/i))
  end

  it "finds no error in a clean workspace" do
    expect(check[:findings].select { |finding| finding[:severity] == :error }).to be_empty
  end

  it "outlines each declaration with its line and the goal or description after it", :aggregate_failures do
    outline = check[:outline]
    account = outline.find { |entry| entry[:kind] == "aggregate" && entry[:name] == "Account" }

    expect(account).to include(file: file, line: 4, summary: "A balance belonging to one customer.")
    expect(outline.find { |entry| entry[:name] == "Credit" }[:summary]).to eq("Put money in")
  end

  it "outlines a draft that does not parse, so a jump still works while it is broken" do
    names = check(misspelt)[:outline].map { |entry| entry[:name] }

    expect(names).to include("Account", "Credit")
  end

  it "reports what the bluebook is wired to", :aggregate_failures do
    wiring = check[:wiring]

    expect(wiring[:binds]).to include(a_hash_including(verb: "persisted_by", adapter: "Memory"))
    expect(wiring[:ports]).to be_a(Hash)
  end

  it "judges the unsaved text, not the file on disk, and names the line", :aggregate_failures do
    diagnostic = check(misspelt)[:diagnostic]

    expect(diagnostic[:file]).to eq(file)
    expect(diagnostic[:line]).to be_a(Integer)
  end

  it "says what would have been accepted where the text was refused" do
    expect(check(misspelt)[:diagnostic][:expected]).not_to be_empty
  end

  it "draws nothing while the text is refused" do
    expect(check(misspelt)[:diagrams]).to be_empty
  end

  it "reports a lifecycle step that no command performs as an error finding", :aggregate_failures do
    result = check(with_unperformed_step)

    expect(result[:diagnostic]).to be_nil
    expect(result[:findings].map { |finding| finding[:severity] }).to include(:error)
  end

  it "leaves the workspace on disk as it found it" do
    before_text = source

    check("Hecks.bluebook \"Ledger\" do\nend\n")

    expect(source).to eq(before_text)
  end

  it "refuses a buffer whose path climbs out of the workspace" do
    expect { described_class.call(dir: dir, buffers: { "../outside.bluebook" => "" }) }
      .to raise_error(Hecks::Composer::Workspace::OutsideWorkspace)
  end
end
