# frozen_string_literal: true

require "spec_helper"

# The board's main page lists its panels top to bottom, and the owner reads them in that order:
# the Pipeline, then what needs attention, then the sessions.
RSpec.describe "the order of the panels on the board's main page" do
  let(:page) { File.read(File.expand_path("../lib/hecks/pipeline_board/adapters/pipeline_web/page.html", __dir__)) }

  def position(id)
    page.index(%(id="#{id}")) || raise("page.html has no element with id #{id}")
  end

  it "lists the Pipeline panel, then Needs attention, then Sessions" do
    expect(%w[h-strip h-attn sessions-panel].map { |id| position(id) }).to eq(
      %w[h-strip h-attn sessions-panel].map { |id| position(id) }.sort
    )
  end
end
