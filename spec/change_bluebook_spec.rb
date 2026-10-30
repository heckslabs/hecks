require "spec_helper"
require "tempfile"

# A change is planned, shown, confirmed against exactly that plan, and only then carried out. The
# bluebook holds how any change moves; the `Script` port's adapter holds what a script does.
RSpec.describe "a change" do
  let(:runner) { Hecks::Adapters::ScriptRunner }
  let(:done) { [] }
  let(:hecks) { Hecks.boot(File.join(InMemoryDomain::ROOT, "lib/hecks/hecks"), install_driving: false) }
  let(:rename_args) { [{ key: "from", value: "a" }, { key: "to", value: "b" }] }

  before { runner.reset! }

  after { runner.reset! }

  # Registers `rename`: its plan names the move, and applying it records the new name.
  def register_rename(plan: ->(args) { "would rename #{args["from"]} to #{args["to"]}" })
    runner.register("rename", plan: plan, apply: ->(args) { (done << args["to"]) && "renamed to #{args["to"]}" })
  end

  def request(run, script: "rename")
    hecks.dispatch_flat("Hecks::Change.Request", run: { value: run }, script: { value: script }, arguments: rename_args)
  end

  def confirm(run, digest) = hecks.dispatch_flat("Hecks::Change.Confirm", run: { value: run }, digest: { value: digest })

  # Requests a change, then makes the script plan something else before the digest is confirmed.
  def confirm_after_the_plan_moves(run)
    register_rename
    request(run)
    digest = shown_digest(run)
    register_rename(plan: ->(_) { "would do something else" })
    confirm(run, digest)
  end

  # The digest a plan of `rename` has, which a person would have reviewed in an earlier run.
  def expected_digest
    runner.new.examine(script: { value: "rename" }, arguments: rename_args)[:digest][:value]
  end

  # One run: asks for the change with the expected digest, carried out in this process.
  # The script's source: this example registers the script itself, so the file only has to exist.
  let(:source) do
    Tempfile.new(["change", ".rb"]).tap { |file| file.write("# registered by the example\n") && file.flush }.path
  end

  def apply(run, expected:)
    hecks.dispatch_flat("Hecks::Change.Apply", run: { value: run }, script: { value: "rename" },
                                              arguments: rename_args, source: { value: source },
                                              expected: { value: expected })
  end

  def standing(run) = hecks.query("Hecks::Change.Outcome", run: { value: run }).first

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

  it "carries out a run whose plan has the expected digest, in one process", :aggregate_failures do
    register_rename
    expected = expected_digest
    apply("c4", expected: expected)

    expect([standing("c4")[:status], said("c4", :report), done]).to eq(["applied", "renamed to b", ["b"]])
  end

  it "refuses a run whose plan does not have the expected digest, and nothing runs", :aggregate_failures do
    register_rename
    apply("c5", expected: "0" * 64)

    expect([standing("c5")[:status], done]).to eq(["faulted", []])
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
