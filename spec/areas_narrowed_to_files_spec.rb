# frozen_string_literal: true

require "spec_helper"
require_relative "support/narrowed_area_world"

# A started work item whose area is a bare directory holds every file under it; once the coder
# rescopes it to the files it edits, another item editing a different file lands beside it, and one
# editing the same file is refused naming the file. Plan and Rescope say so in their goals.
RSpec.describe "An item's area narrowed to the files it edits" do
  include NarrowedAreaWorld

  let(:work) { InMemoryDomain.boot_hecks_in_memory.registry.bluebook("Tickets").aggregate("Work") }

  after { FileUtils.remove_entry(repo) }

  before do
    init_repo
    landing("b", "spec/b_spec.rb")
    landing("a", "spec/a_spec.rb")
  end

  def goal(verb) = work.commands.find { |command| command.hecks_name == verb }.goal.to_s

  it "holds every spec file while the area is the bare directory" do
    expect(rivals_refusal("b", ["spec"])).to include("spec/b_spec.rb")
  end

  it "lands another item's file beside an area narrowed to one spec file" do
    expect(rivals_refusal("b", ["spec/a_spec.rb"])).to be_nil
  end

  it "refuses the narrowed file itself, naming it" do
    expect(rivals_refusal("a", ["spec/a_spec.rb"])).to include("spec/a_spec.rb")
  end

  it "says in Plan that an area is a directory or a file and a bare directory blocks the rest" do
    expect(goal("Plan")).to include("file", "directory", "bare")
  end

  it "says in Rescope that it narrows an area to the files an item edits" do
    expect(goal("Rescope")).to include("file", "narrow")
  end
end
