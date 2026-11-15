# frozen_string_literal: true

require "spec_helper"

# The board's menu bar is not a scroll container where it is shown in full, so a wheel over it
# moves the page; the folded menu below the narrow breakpoint sets its own overflow.
RSpec.describe "the board's menu bar scroll" do
  let(:css) { File.read(File.expand_path("../lib/hecks/pipeline_board/adapters/pipeline_web/board.css", __dir__)) }
  let(:rule) { css[/^nav\.pages \{[^}]*\}/] }

  it "declares no overflow on the unconditional nav.pages rule" do
    expect(rule).not_to include("overflow")
  end
end
