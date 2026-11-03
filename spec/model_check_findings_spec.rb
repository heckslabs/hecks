require "spec_helper"

# The finding kinds `hecks model_check` reports are declared in vocabulary.bluebook
# (ModelCheckFinding). This holds that table to the kinds the checks emit, in both directions, so
# a check cannot report a kind nobody declared and a declared kind cannot outlive its check.
RSpec.describe "The model_check finding kinds" do
  # Each `Finding.new(kind:, severity:)` in the checks as [kind, severity, check file]. A severity
  # that is not a literal (rust_reserved_name takes the run's) reads "severity".
  def emitted
    root = File.expand_path("..", __dir__)
    sources = [File.join(root, "lib/hecks/bluebook/model_check.rb"),
               *Dir[File.join(root, "lib/hecks/bluebook/model_check/*.rb")]]
    sources.flat_map do |path|
      File.read(path).scan(/Finding\.new\(kind: :(\w+), severity: (:?\w+)/).map do |kind, severity|
        [kind, severity.delete_prefix(":"), File.basename(path, ".rb")]
      end
    end
  end

  let(:declared) { Hecks::Vocabulary.rows("ModelCheckFinding") }
  let(:declared_kinds) { declared.map { |row| row["kind"] } }

  it "declares every kind a check emits" do
    expect(emitted.map(&:first) - declared_kinds).to be_empty
  end

  it "declares no kind that no check emits" do
    expect(declared_kinds - emitted.map(&:first)).to be_empty
  end

  it "declares each kind once" do
    expect(declared_kinds).to eq(declared_kinds.uniq)
  end

  it "declares the check each emission comes from" do
    mismatched = emitted.reject { |kind, _, check| declared.find { |row| row["kind"] == kind }["check"] == check }
    expect(mismatched).to be_empty
  end

  it "declares the severity each emission carries" do
    literal = emitted.reject { |_, severity, _| severity == "severity" }
    mismatched = literal.reject { |kind, severity, _| declared.find { |row| row["kind"] == kind }["severity"] == severity }
    expect(mismatched).to be_empty
  end

  it "uses only the severities the table names" do
    expect(declared.map { |row| row["severity"] } - %w[error warning]).to be_empty
  end

  it "uses only the acknowledgement targets the table names" do
    expect(declared.map { |row| row["acknowledged_on"] } - ["", "aggregate", "relationship"]).to be_empty
  end

  it "uses only the acknowledgement subjects the table names" do
    expect(declared.map { |row| row["subject"] } - ["", "attribute", "referenced aggregate"]).to be_empty
  end

  it "lets only the kinds declared as acknowledgeable be acknowledged on an aggregate" do
    expect(Hecks::Bluebook::Acknowledgements::AGGREGATE_KINDS).to match_array(
      %i[large_aggregate key_by_value orphaned_reference no_command_surface]
    )
  end
end
