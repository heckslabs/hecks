require "spec_helper"
require "hecks/vocabulary"
require "hecks/hecks/adapters/git_train"

# The drift checks a push train runs before it boards are the `boarding` GateStage row, and that row
# only compares: a boarding never rewrites a file in the checkout it carries.
RSpec.describe "the boarding GateStage" do
  let(:stage) { Hecks::Vocabulary.rows("GateStage").find { |row| row["name"] == "boarding" } }
  let(:checks) { Hecks::Vocabulary.rows("GateCheck") }

  it "is a stage row that the settlement runs before a boarding pushes", :aggregate_failures do
    expect(stage).not_to be_nil
    expect(Hecks::Adapters::GitTrain::Settlement::DRIFT)
      .to eq([%w[bundle exec exe/hecks gate_run.gate! stage=boarding --wait]])
  end

  it "lists only checks that resolve to a GateCheck row" do
    names = stage.fetch("checks").split(",")
    listed = names.map { |name| checks.find { |check| check["name"] == name } }

    expect(listed).to all(be_truthy), "boarding lists a check with no GateCheck row: #{names - checks.map { |c| c["name"] }}"
  end

  it "runs no check that writes: none names --confirm" do
    stage.fetch("checks").split(",").each do |name|
      check = checks.find { |row| row["name"] == name }

      expect("#{check["argv"]} #{check["script"]}").not_to include("--confirm"), "#{name} would write in a boarding"
    end
  end
end
