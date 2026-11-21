# frozen_string_literal: true

require "spec_helper"
require "hecks/hecks/adapters/dispatching"
require "hecks/roundhouse/adapters/metering"

# The helper share read off Roundhouse's own meter: a fill's coders are dispatched with no agent, as
# `works_as: coder`, and still count toward the share, so helpers are rated against the coders.
RSpec.describe "the helper share on Roundhouse's meter" do
  def entry(pid, name) = { "sessionId" => "s#{pid}", "pid" => pid, "name" => name, "kind" => "background", "startedAt" => 0 }

  def listing = [101, 102, 103].map { |pid| entry(pid, "coder-#{pid}") } + [entry(201, "helper-a"), entry(202, "helper-b")]

  def runs = [101, 102, 103].to_h { |pid| ["s#{pid}", { run: "item-#{pid}", agent: "", works_as: "coder", work: "" }] }

  def metering
    rows = listing
    ps = rows.map { |row| "#{row["pid"]} 1 1024 0.0 claude" }.join("\n")
    Hecks::Adapters::Metering.new(settings: { listing: -> { rows }, processes: -> { ps }, runs: -> { runs },
                                              machine: -> { {} }, activity: ->(_) {}, copies: -> { [] } })
  end

  it "reads three started coders and two helpers as helpers 2 of 3" do
    door = Hecks::Adapters::Dispatching::SignalboxDoor.new
    protecting = Hecks::Adapters::Dispatching::Protecting.new(share: -> {},
                                                              sessions: -> { metering.rows }, door: door)
    expect(protecting.clause).to include("helpers 2 of 3 helpers")
  end
end
