# frozen_string_literal: true

require "spec_helper"
require "hecks/pipeline_board/adapters/pipeline_stages"
require_relative "support/board_rows"
require_relative "support/glance_facts"

# The board's `Glance`, whether work is flowing: admission. The `StuckKind` and `Verdict` rows decide
# the members and how long is too long; the adapter only reshapes the facts it is handed.
RSpec.describe Hecks::Adapters::PipelineBoard::GlanceRows, ".build" do
  include BoardRows
  include GlanceFacts

  it "says admission is closed while an overload stands, with its reason" do
    expect(flowing(overloads: [{ reason: "load 31 over 20" }])).to include(admission: "closed", admission_why: "load 31 over 20")
  end

  it "says admission is closed while the load guard holds" do
    expect(flowing(overloads:  [],
                   load_guard: { load:  31.0,
                                 limit: 20.0 })).to include(admission: "closed", admission_why: /31.0 is above 20.0/)
  end

  it "says admission is open when nothing standing was found" do
    expect(flowing(overloads: [])).to include(admission: "open", admission_why: "")
  end

  it "says admission is unknown when nothing was read" do
    expect(flowing({})).to include(admission: "unknown")
  end
end
