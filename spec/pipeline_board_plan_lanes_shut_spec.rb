# frozen_string_literal: true

require "spec_helper"

# The planning page draws every lane (now, next, later) shut: the heading and its counts show, the epic rows open
# on a click, the choice is kept, and a filter opens the lanes it found something in.
RSpec.describe "the plan page's lanes" do
  let(:page) { File.read(File.expand_path("../lib/hecks/pipeline_board/adapters/pipeline_web/plan.html", __dir__)) }

  it "hides a shut lane's epic rows" do
    expect(page).to include(".lane.shut > details.epic { display: none; }")
  end

  it "shuts a lane unless the owner opened it or a filter found something in it" do
    expect(page).to include('classList.toggle("shut", !(filtering || laneOpen[lane.dataset.lane]))')
  end

  it "keeps the lanes the owner opened across visits" do
    expect(page).to include('localStorage.setItem("plan-lanes"')
  end

  it "opens and shuts a lane from its heading" do
    expect(page).to include('event.target.closest("#plan .lane > h2")')
  end
end
