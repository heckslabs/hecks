require "spec_helper"
require "json"
require "hecks/hecks/adapters/work_landings"

# A work item is done only when a landing of its branch is on main, or when its finish names why it
# lands nothing. A bare `Work.finish!` with no landing is refused by name and leaves the item as it
# was; the WorkLandings port reads the landing records and `main`.
RSpec.describe "finishing a work item" do
  before(:all) { @hecks = InMemoryDomain.boot_hecks_in_memory }

  def cli(*argv)
    out, = Hecks::Adapters::Driving::CliRunner.call(runtime: @hecks, program: "hecks", argv: ["tickets", *argv, "--wait"])
    out
  end

  def finished(key, *args) = JSON.parse(cli("Work.finish!", "to=#{key}", *args))["state"]

  def planned(key) = cli("Work.plan!", "work.value=#{key}", "title.value=Change #{key}")

  def landed_on_main(sha)
    items = instance_double(Hecks::Adapters::Dispatching::WorkItems, landed_commits: [sha])
    allow(Hecks::Adapters::Dispatching::WorkItems).to receive(:new).and_return(items)
    allow(Hecks::Adapters::Git).to receive(:new).and_return(instance_double(Hecks::Adapters::Git, ancestor?: true))
  end

  it "refuses a finish with no landing on main, by name" do
    planned("unlanded")
    expect(finished("unlanded")).to include("status" => "planned", "refusal" => include("unlanded has no landing on main"))
  end

  it "closes a finish that names why it lands nothing" do
    planned("a-verify")
    expect(finished("a-verify", "no_change.value=a verify")).to include("status" => "done", "no_change" => "a verify")
  end

  it "closes a finish whose branch landed on main, with the landing" do
    planned("landed")
    landed_on_main("abc123def")
    expect(finished("landed")).to include("status" => "done", "landing" => "abc123def")
  end
end
