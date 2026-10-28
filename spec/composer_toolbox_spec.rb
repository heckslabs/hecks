require "spec_helper"
require "hecks/composer/toolbox"

# The Toolbox runs Hecks's own commands and queries in-process for the Composer's palette. One
# toolbox is shared by the group because booting the Hecks bluebook takes about a second.
RSpec.describe Hecks::Composer::Toolbox do
  before(:all) { @toolbox = described_class.new }

  let(:toolbox) { @toolbox }

  def fixture = File.expand_path("fixtures/composer/account", __dir__)

  def catalog = toolbox.catalog

  def guarded_command = catalog.find { |row| row[:kind] == "command" && row[:guarded] }

  it "lists commands and queries, sorted by verb", :aggregate_failures do
    expect(catalog.map { |row| row[:kind] }.uniq).to contain_exactly("command", "query")
    expect(catalog.map { |row| row[:verb] }).to eq(catalog.map { |row| row[:verb] }.sort)
  end

  it "marks a command outside the safe list as guarded and every query as safe", :aggregate_failures do
    expect(guarded_command[:verb]).not_to be_nil
    expect(catalog.select { |row| row[:kind] == "query" }.map { |row| row[:guarded] }).to all(be(false))
  end

  it "keeps the safe commands inside the real command verbs" do
    verbs = catalog.select { |row| row[:kind] == "command" }.map { |row| row[:verb] }

    expect(described_class::SAFE_COMMANDS - verbs).to eq([])
  end

  it "answers a query with the workspace's shape", :aggregate_failures do
    result = toolbox.run(kind: "query", verb: "introspection.shape", args: { "domain.value" => fixture })

    expect(result[:ok]).to be(true)
    expect(result[:output]).to start_with("Ledger")
  end

  it "runs a safe command" do
    result = toolbox.run(kind: "command", verb: "model_check_run.model_check",
                         args: { "domains.value" => fixture })

    expect(result[:ok]).to be(true)
  end

  it "refuses a guarded command without confirmation and runs nothing", :aggregate_failures do
    allow(Hecks::Adapters::Driving::CliRunner).to receive(:call).and_call_original
    result = toolbox.run(kind: "command", verb: guarded_command[:verb])

    expect(result).to include(ok: false, status: 2, output: "")
    expect(Hecks::Adapters::Driving::CliRunner).not_to have_received(:call)
  end

  it "refuses a newline in a name or a value", :aggregate_failures do
    value = toolbox.run(kind: "query", verb: "introspection.shape", args: { "domain.value" => "a\nb" })
    name = toolbox.run(kind: "query", verb: "introspection.shape", args: { "a\nb" => "x" })

    expect(value).to include(ok: false, output: "")
    expect(name).to include(ok: false, output: "")
  end

  it "refuses an unknown verb without raising", :aggregate_failures do
    result = toolbox.run(kind: "command", verb: "nothing.here")

    expect(result[:ok]).to be(false)
    expect(result[:error]).to include("nothing.here")
  end

  it "gives the help text of a verb" do
    expect(toolbox.help(kind: "query", verb: "era.audit_translation")).not_to be_empty
  end

  it "reads the four era queries of a workspace", :aggregate_failures do
    eras = toolbox.eras(fixture)

    expect(eras.keys).to eq(%i[shape scaffold_translation audit_translation compaction])
    expect(eras.values).to all(include(:ok, :status, :output))
    expect(eras[:shape][:output]).to start_with("Ledger")
  end
end
