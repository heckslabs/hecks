# frozen_string_literal: true

require "spec_helper"

# A reading the load guard held back runs again when the load falls, so it is waiting, and what
# waiting looks like on the board is Una turning beside the words. The pages are scripts in HTML, so
# the spec reads what each page does with such a reading.
RSpec.describe "a reading the load guard held back, on the board's pages" do
  let(:web) { File.expand_path("../lib/hecks/pipeline_board/adapters/pipeline_web", __dir__) }
  let(:held) { /not run: load \[\\d\.\]\+ is above \[\\d\.\]\+/ }

  it "shows Una on the board page, with the paused words" do
    page = File.read(File.join(web, "page.html"))

    expect(page).to match(/#{held.source}[^\n]*\)\) \{\n\s*return una\(tidy\(/)
  end

  it "shows Una on the CI page, with the paused words" do
    ci = File.read(File.join(web, "ci.html"))

    expect(ci).to include("held(reading) ? una(why(reading), true)")
  end
end
