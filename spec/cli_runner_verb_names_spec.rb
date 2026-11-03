require "spec_helper"

# A command is reached by its snake-case launcher name or by the bluebook's verb form, so a line
# copied from `dispatches Hecks::SendTrain.Board` runs as it reads.
RSpec.describe "the launcher's verb-form command names" do
  before(:all) do
    @runtime = Hecks.boot(File.join(InMemoryDomain::ROOT, "lib/hecks/hecks"), install_driving: false)
  end

  def help(word)
    Hecks::Adapters::Driving::CliRunner.call(runtime: @runtime, argv: [word, "--help"], program: "hecks")
  end

  def board_help = help("send_train.board!")

  %w[SendTrain.board! Hecks::SendTrain.board! SendTrain.Board Hecks::SendTrain.Board].each do |spelling|
    it "reaches send_train.board as #{spelling}" do
      expect(help(spelling)).to eq(board_help)
    end
  end

  it "keeps the snake-case name working, and prints the verb form", :aggregate_failures do
    expect(board_help.first).to start_with("SendTrain.board")
    expect(board_help.last).to eq(0)
  end

  it "reaches an entity's command by the verb that names the entity" do
    expect(help("Hecks::SendTrain.Launcher.Refresh").first).to start_with("SendTrain.refresh")
  end

  it "suggests near names in the verb form for a misspelled verb" do
    expect(help("SendTrain.bord!").first).to include("did you mean:", "  SendTrain.board")
  end

  it "refuses a verb that names nothing, naming what was typed", :aggregate_failures do
    text, status = help("SendTrain.nope!")

    expect(text).to include("no such command: SendTrain.nope")
    expect(status).to eq(2)
  end
end
