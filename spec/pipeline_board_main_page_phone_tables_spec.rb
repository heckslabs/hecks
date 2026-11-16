# frozen_string_literal: true

require "spec_helper"

# On a phone the Needs attention cards (`.attn-group`, one table each) were clipped: the table ran
# past its card, which did not scroll. The card holds its table now, and under 600px each row
# stacks as a small card.
RSpec.describe "the board's main page on a phone" do
  let(:page) { File.read(File.expand_path("../lib/hecks/pipeline_board/adapters/pipeline_web/page.html", __dir__)) }
  let(:narrow) { page[/@media \(max-width: 600px\) \{.*?\n\}\n/m] }

  it "lets the attention card and the scroll wrapper shrink and scroll inside their column" do
    expect(page).to include(".attn-group, .scroll { min-width: 0; max-width: 100%; overflow-x: auto; }")
  end

  it "lets the two-up grid shrink below its 340px column on a narrow screen" do
    expect(page).to include("minmax(min(340px, 100%), 1fr)")
  end

  it "stacks each six-column attention row under 600px" do
    expect(narrow).to include("table:has(th:nth-child(6))")
  end

  it "makes each cell of a stacked row a block line" do
    expect(narrow).to include("td { display: block; }")
  end

  it "labels the sixth cell Since" do
    expect(narrow).to include('td:nth-child(6)::before { content: "Since"; }')
  end

  it "lets long values wrap anywhere" do
    expect(narrow).to include("overflow-wrap: anywhere")
  end
end
