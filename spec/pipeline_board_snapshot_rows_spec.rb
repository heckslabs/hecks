# frozen_string_literal: true

require "spec_helper"
require "hecks/pipeline_board/adapters/pipeline_stages"
require_relative "support/board_rows"
require_relative "support/board_state_fixture"

# ADR 0195 point 1: the board's state reshaped as the one `Snapshot` row. Every number is one
# `Stage` or `Reading` under one key, a failed read is a row in state `unknown`, and what is
# stuck names the run that owns it.
RSpec.describe Hecks::Adapters::PipelineBoard::SnapshotRows do
  include BoardRows

  def row(extras = {}) = described_class.build(BoardStateFixture.state, extras)

  it "answers a row the bluebook accepts as a Snapshot" do
    answered = row(train_prs: [BoardStateFixture::PULL], release: { tag: "v7.0.0" })
    expect(built("Snapshot", answered)).to include(generated_at: BoardStateFixture::AT, stale_seconds: 0)
  end

  it "gives every stage and reading a key of its own" do
    keys = (row[:stages] + row[:readings] + row[:roles]).map { |reading| reading[:key] }
    expect(keys).to eq(%w[red_flag release release_age disk role_coder])
  end

  it "keeps a failed read as a Reading in state unknown, its reason in the note" do
    expect(row[:readings].last).to include(key: "disk", state: "unknown", value: "", note: "unknown: df failed")
  end

  it "lists the red main, the owner's question and the stalled session as stuck, each with its run" do
    expect(row[:stuck].map { |item| item.values_at(:kind, :owner_run, :group, :waits_on) })
      .to eq([["red_main", "", "standing too long", ""], ["owner_ask", "r1", "waiting on a person", "owner"],
              ["stalled_session", "r2", "standing too long", ""]])
  end

  it "gives a run card to each session that holds a run, with its last word" do
    cards = row(turns: [{ "run" => "r2", "verdict" => "routed" }])[:runs]
    expect(cards.map { |card| card.values_at(:run, :role, :idle_seconds, :last_word) })
      .to eq([["r1", "", 0, ""], ["r2", "coder", 1200, "routed"]])
  end
end
