require "spec_helper"

# A command is reached by its snake-case launcher name or by the bluebook's verb form, so a line
# copied from `dispatches Hecks::ModelCheckRun.ModelCheck` runs as it reads.
RSpec.describe "the launcher's verb-form command names" do
  before(:all) do
    @runtime = boot_hecks_in_memory
  end

  def help(word)
    Hecks::Adapters::Driving::CliRunner.call(runtime: @runtime, argv: [word, "--help"], program: "hecks")
  end

  def check_help = help("model_check_run.model_check!")

  %w[ModelCheckRun.model_check! Hecks::ModelCheckRun.model_check! ModelCheckRun.ModelCheck
     Hecks::ModelCheckRun.ModelCheck].each do |spelling|
    it "reaches model_check_run.model_check as #{spelling}" do
      expect(help(spelling)).to eq(check_help)
    end
  end

  it "keeps the snake-case name working, and prints the verb form", :aggregate_failures do
    expect(check_help.first).to start_with("ModelCheckRun.model_check")
    expect(check_help.last).to eq(0)
  end

  it "reaches a port's ask by the verb that names the port" do
    expect(help("Hecks::Operation.DomainRuntime.Refresh").first).to start_with("Operation.refresh")
  end

  it "suggests near names in the verb form for a misspelled verb" do
    expect(help("ModelCheckRun.model_chek!").first).to include("did you mean:", "  ModelCheckRun.model_check")
  end

  it "refuses a verb that names nothing, naming what was typed", :aggregate_failures do
    text, status = help("ModelCheckRun.nope!")

    expect(text).to include("no such command: ModelCheckRun.nope")
    expect(status).to eq(2)
  end
end
