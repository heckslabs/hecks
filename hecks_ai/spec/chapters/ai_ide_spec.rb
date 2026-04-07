# AI::IdeAggregates paragraph spec
#
# Verifies IDE aggregates exist within the AI domain.
#
require "spec_helper"
require "hecks/chapters/ai"

RSpec.describe Hecks::Chapters::AI::IdeAggregates do
  subject(:domain) { Hecks::Chapters::AI.definition }

  it "includes Server with Run command" do
    agg = domain.aggregates.find { |a| a.name == "Server" }
    expect(agg).not_to be_nil
    expect(agg.commands.map(&:name)).to include("Run")
  end

  it "includes Routes with ServePage and HandlePrompt commands" do
    agg = domain.aggregates.find { |a| a.name == "Routes" }
    expect(agg).not_to be_nil
    expect(agg.commands.map(&:name)).to include("ServePage", "HandlePrompt")
  end

  it "includes ClaudeProcess with SendPrompt and Interrupt" do
    agg = domain.aggregates.find { |a| a.name == "ClaudeProcess" }
    expect(agg).not_to be_nil
    expect(agg.commands.map(&:name)).to include("SendPrompt", "Interrupt")
  end

  it "includes SessionWatcher with Start and Stop" do
    agg = domain.aggregates.find { |a| a.name == "SessionWatcher" }
    expect(agg).not_to be_nil
    expect(agg.commands.map(&:name)).to include("Start", "Stop")
  end

  it "includes ScreenshotHandler with Save" do
    agg = domain.aggregates.find { |a| a.name == "ScreenshotHandler" }
    expect(agg).not_to be_nil
    expect(agg.commands.map(&:name)).to include("Save")
  end
end
