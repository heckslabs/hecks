require "spec_helper"

# A command is reached by its snake-case launcher name or by the bluebook's verb form, so a line
# copied from `dispatches Hecks::PushTrain.Board` runs as it reads.
RSpec.describe "the launcher's verb-form command names" do
  before(:all) do
    @runtime = Hecks.boot(File.join(InMemoryDomain::ROOT, "lib/hecks/hecks"), install_driving: false)
  end

  def help(word)
    Hecks::Adapters::Driving::CliRunner.call(runtime: @runtime, argv: [word, "--help"], program: "hecks")
  end

  def board_help = help("push_train.board!")

  %w[PushTrain.board! Hecks::PushTrain.board! PushTrain.Board Hecks::PushTrain.Board].each do |spelling|
    it "reaches push_train.board as #{spelling}" do
      expect(help(spelling)).to eq(board_help)
    end
  end

  it "keeps the snake-case name working, and prints the verb form", :aggregate_failures do
    expect(board_help.first).to start_with("PushTrain.board")
    expect(board_help.last).to eq(0)
  end

  it "reaches an entity's command by the verb that names the entity" do
    expect(help("Hecks::PushTrain.Launcher.Refresh").first).to start_with("PushTrain.refresh")
  end

  it "suggests near names in the verb form for a misspelled verb" do
    expect(help("PushTrain.bord!").first).to include("did you mean:", "  PushTrain.board")
  end

  it "refuses a verb that names nothing, naming what was typed", :aggregate_failures do
    text, status = help("PushTrain.nope!")

    expect(text).to include("no such command: PushTrain.nope")
    expect(status).to eq(1)
  end
end
