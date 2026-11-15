# frozen_string_literal: true

require "spec_helper"
require "hecks/pipeline_board/adapters/pipeline_web"

# The board opens and closes a merge window with the same commands the command line takes: two steps
# from the `ActionRule` rows, a journal read of the newest opening and closing, and a card on the CI
# page that needs two taps to open and one to close.
RSpec.describe "the merge window on the board" do
  let(:board) { Hecks::Adapters::PipelineBoard }
  let(:ci_page) { File.read(File.expand_path("../lib/hecks/pipeline_board/adapters/pipeline_web/ci.html", __dir__)) }

  it "opens a window with the reason typed, and only when the page confirms", :aggregate_failures do
    words = board::Actions.argv("open_window", { text: "train 1454" }, confirm: true)

    expect(words).to eq(["MergeWindow.open!", "reason.value=train 1454", "opened_by.value=board", "--wait"])
    expect { board::Actions.argv("open_window", { text: "x" }, confirm: false) }
      .to raise_error(board::Unavailable, /confirm/)
  end

  it "closes the window the page names, which needs no confirmation" do
    expect(board::Actions.argv("close_window", { target: "w1" }, confirm: false)).to eq(["MergeWindow.close!", "to=w1", "--wait"])
  end

  it "reads the newest opening and closing from the journal" do
    reads = board::Gather::READS.slice(:window_opened, :window_closed)

    expect(reads.values.map { |read| read.first(2) }).to eq([%i[journal named]] * 2)
  end

  it "shows the card on the CI page, two taps to open it and one to close it", :aggregate_failures do
    expect(ci_page).to include('action: "open_window"', 'action: "close_window"', "renderWindow(s)")
    expect(ci_page).to include("Tap again to open it")
  end
end
