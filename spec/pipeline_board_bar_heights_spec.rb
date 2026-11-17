# frozen_string_literal: true

require "spec_helper"

# A column chart's bar shares its column with the count label above it. A bar sized as a percentage
# of the whole column is squeezed when it and its label do not fit, so the tallest bars lose their
# differences (98 drew 7% taller than 81). Each chart sizes a bar against the room under the label
# and stops it shrinking.
RSpec.describe "the height of a bar on the board's column charts" do
  def page(name) = File.read(File.expand_path("../lib/hecks/pipeline_board/adapters/pipeline_web/#{name}", __dir__))

  SHARE = 'style: "height:calc((100% - var(--val)) * "'

  it "sizes a finished-per-day bar against the room under its label" do
    expect(page("page.html")).to include(SHARE).and include(".thru .cols { --val: 16px; }")
  end

  it "stops a finished-per-day bar and its label from shrinking" do
    expect(page("page.html")).to include("background: var(--good); flex: none; }")
      .and include("line-height: var(--val); flex: none; }")
  end

  it "sizes a CI run's bar against the room under its label" do
    expect(page("ci.html")).to include(SHARE).and include(".runs { --val: 16px; }")
  end

  it "stops a CI run's bar from shrinking" do
    expect(page("ci.html")).to include(".runs .bar { flex: none;")
  end

  it "draws no bar as a bare percentage of its column" do
    expect(%w[page.html ci.html].map { |name| page(name) }.join).not_to include('class: "bar", style: "height:" + Math.round')
  end
end
