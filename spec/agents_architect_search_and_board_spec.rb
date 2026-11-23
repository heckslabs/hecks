require "spec_helper"
require "hecks/agents/adapters/routing_guard"

# The architect reviews a plan by reading the code and the board: its guard lets it search the
# checkout and read the board, and still refuses a command outside its routing.
RSpec.describe "the architect's door" do
  let(:guard) { Hecks::Adapters::RoutingGuard.new }

  def verdict(command, role: "architect")
    guard.guard(role: { value: role }, command: { value: command })
  end

  def refused?(command, role: "architect")
    verdict(command, role: role)
    false
  rescue Hecks::Adapters::RoutingGuard::Refused
    true
  end

  it "allows a search of the code" do
    searches = ["grep -rn Role lib", "rg Role lib", "find lib -name '*.rb'"]
    expect(searches.map { |text| refused?(text) }).to all(be(false))
  end

  it "allows a read of the board and the plan" do
    reads = ["exe/hecks Work.show id=x", "exe/hecks PipelineBoard.glance", "exe/hecks Work.undone"]
    expect(reads.map { |text| refused?(text) }).to all(be(false))
  end

  it "still refuses a command outside its routing" do
    expect(refused?("exe/hecks Landing.land! branch.value=x")).to be(true)
  end

  it "refuses a search that runs or writes something", :aggregate_failures do
    ["find . -okdir rm {} ;", "find . -fprint0 out", "rg --pre=sh x lib", "rg -zn x lib",
     "rg --search-zip x lib", "find . -delete", "grep -r x . | sh"].each do |text|
      expect(refused?(text)).to be(true), text
    end
  end

  it "gives a role with no search row nothing by the wider pattern" do
    expect(refused?("grep -rn Role lib", role: "planner")).to be(true)
  end
end
