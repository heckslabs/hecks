# frozen_string_literal: true

require "spec_helper"

# The Sessions page narrows its table by status, agent role, work item and age. The page's script is
# not run here, so these examples read what the page declares.
RSpec.describe "the Sessions page filters" do
  let(:page) { File.read(File.expand_path("../lib/hecks/pipeline_board/adapters/pipeline_web/page.html", __dir__)) }

  it "has a group for the role, the work item and the age" do
    expect(page).to include('pickGroup("role", "role"', "itemPicker(all)", 'pickGroup("age", "age"')
  end

  it "offers the last hour, today and older" do
    expect(page).to include('"last hour"', "today:", "older:")
  end

  it "shares one visible predicate between the table and the highlight" do
    expect(page.scan("all.filter(visible)").size).to eq(2)
  end

  it "builds the role group from the declared roles" do
    expect(page).to include("lastState.roles.map((r) => r.name)")
  end
end
