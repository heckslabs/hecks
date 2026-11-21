# frozen_string_literal: true

require "spec_helper"
require "hecks/pipeline_board/adapters/pipeline_stages"
require_relative "support/board_rows"
require_relative "support/glance_facts"

# The board's `Glance`, the list as a whole. The `StuckKind` and `Verdict` rows decide
# the members and how long is too long; the adapter only reshapes the facts it is handed.
RSpec.describe Hecks::Adapters::PipelineBoard::GlanceRows, ".build" do
  include BoardRows
  include GlanceFacts

  it "puts what waits on a person before what stands too long" do
    data = { sessions: [GlanceFacts::STALLED, GlanceFacts::OWNER_ASK] }
    expect(glance(data)[:entries].map { |item| item[:group] }).to eq(["waiting on a person", "standing too long"])
  end

  it "names a group, a person or role to wait on and a plain line for every entry", :aggregate_failures do
    every = glance(everything)[:entries]
    expect(every.map { |item| item[:kind] }.uniq.size).to eq(every.size)
    expect(every).to all(include(waits_on_kind: a_string_matching(/\A(role|person)\z/), what: a_string_matching(/\S/)))
  end

  it "never says you, in any line a row writes or an entry reads" do
    lines = Hecks::Adapters::PipelineBoard::Rules.rows("StuckKind").map { |row| row[:says] }
    expect(lines + glance(everything)[:entries].map { |item| item[:what] }).not_to include(a_string_matching(/\byou\b/i))
  end

  it "answers a row the bluebook accepts as a Glance" do
    expect(built("Glance", glance(everything)).keys).to eq(%i[entries flowing])
  end
end
