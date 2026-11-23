require "spec_helper"
require "tmpdir"

# A run left refused or requested past a declared age is closed with a reason, so the fills, the
# board and the scrum master stop reading it. A request whose work item is still planned and ranked
# is kept. The runtime is in Memory and the repository named is absent, so the dispatch is refused
# and no session is started.
RSpec.describe "AgentRun closing a request nothing will act on" do
  before(:all) do
    @hecks = boot_hecks_in_memory
  end

  let(:gone) { File.join(Dir.tmpdir, "hecks-closed-absent", "repo") }

  def launch(*argv) = Hecks::Adapters::Driving::CliRunner.call(runtime: @hecks, argv: argv, program: "hecks")

  def store = @hecks.registry.repository("Hecks", @hecks.registry.bluebook("Hecks").aggregate("AgentRun"))

  def refused_run(run)
    launch("agent_run.dispatch!", "run.value=#{run}", "repo.value=#{gone}", "brief.value=say ok", "--wait")
    store.find(run)
  end

  def close(run, held:, age: 3600, now: store.find(run)[:requested_at][:value] + 7200)
    launch("agent_run.close!", "to=#{run}", "age.value=#{age}", "now.value=#{now}", "held.value=#{held}",
           "refusal.value=nothing will act on it", "--wait").first.to_s
  end

  it "closes a refused run past its age, with the reason", :aggregate_failures do
    expect(refused_run("c-old")[:status]).to eq("refused")
    expect(close("c-old", held: false)).to include("AgentRunClosed")
    closed = store.find("c-old")
    expect([closed[:status], closed[:refusal].value]).to eq(["closed", "nothing will act on it"])
  end

  it "keeps a request whose work item is still planned and ranked" do
    refused_run("c-held")
    close("c-held", held: true)
    expect(store.find("c-held")[:status]).to eq("refused")
  end

  it "keeps a run that has not yet passed its age" do
    refused_run("c-new")
    close("c-new", held: false, now: store.find("c-new")[:requested_at][:value] + 60)
    expect(store.find("c-new")[:status]).to eq("refused")
  end
end
