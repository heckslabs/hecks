require "spec_helper"

# A change is planned, shown, confirmed against exactly that plan, and only then carried out. The
# chapter holds how any change moves; the `Script` port's adapter holds what a script does.
RSpec.describe "a change" do
  let(:runner) { Hecks::Adapters::ScriptRunner }
  let(:done) { [] }
  let(:hecks) { Hecks.boot(File.join(InMemoryDomain::ROOT, "lib/hecks/framework"), install_driving: false) }
  let(:rename_args) { [{ key: "from", value: "a" }, { key: "to", value: "b" }] }

  before { runner.reset! }

  after { runner.reset! }

  # Registers `rename`: its plan names the move, and applying it records the new name.
  def register_rename(plan: ->(args) { "would rename #{args["from"]} to #{args["to"]}" })
    runner.register("rename", plan: plan, apply: ->(args) { (done << args["to"]) && "renamed to #{args["to"]}" })
  end

  def request(run, script: "rename")
    hecks.dispatch_flat("Change::Change.Request", run: { value: run }, script: { value: script }, arguments: rename_args)
  end

  def confirm(run, digest) = hecks.dispatch_flat("Change::Change.Confirm", run: { value: run }, digest: { value: digest })

  # Requests a change, then makes the script plan something else before the digest is confirmed.
  def confirm_after_the_plan_moves(run)
    register_rename
    request(run)
    digest = shown_digest(run)
    register_rename(plan: ->(_) { "would do something else" })
    confirm(run, digest)
  end

  def standing(run) = hecks.query("Change::Change.Outcome", run: { value: run }).first

  def shown_digest(run) = standing(run)[:planned_digest][:value]

  def said(run, field) = standing(run)[field][:value]

  it "is planned as soon as it is requested, and nothing has run", :aggregate_failures do
    register_rename
    request("c1")

    expect(standing("c1")[:status]).to eq("planned")
    expect(said("c1", :plan)).to eq("would rename a to b")
    expect(done).to be_empty
  end

  it "carries out the plan once it is confirmed with the digest it was shown", :aggregate_failures do
    register_rename
    request("c2")
    confirm("c2", shown_digest("c2"))

    expect([standing("c2")[:status], said("c2", :report), done]).to eq(["applied", "renamed to b", ["b"]])
  end

  it "refuses a digest that is not the one planned, and nothing runs", :aggregate_failures do
    register_rename
    request("c3")

    expect { confirm("c3", "0" * 64) }.to raise_error(StandardError, /the digest confirmed is the digest planned/)
    expect(standing("c3")[:status]).to eq("planned")
    expect(done).to be_empty
  end

  it "faults instead of applying when the plan moved after it was confirmed", :aggregate_failures do
    confirm_after_the_plan_moves("c4")

    expect(standing("c4")[:status]).to eq("faulted")
    expect([said("c4", :refusal).include?("the plan moved"), done]).to eq([true, []])
  end

  it "faults a change that names a script nobody registered" do
    request("c5", script: "missing")

    expect(said("c5", :refusal)).to include(%(no script is registered as "missing"))
  end
end
