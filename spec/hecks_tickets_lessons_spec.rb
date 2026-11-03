require "spec_helper"

# A kind of red cause is recorded once. Each run that hits it is a sighting, and the count of a kind
# is the sightings of that kind, never a number a caller sets.
RSpec.describe "the lessons a red cause is triaged into" do
  let(:hecks) { boot_hecks_in_memory }

  def cli(*argv)
    out, = Hecks::Adapters::Driving::CliRunner.call(runtime: hecks, program: "hecks", argv: ["tickets", *argv])
    out
  end

  def record(kind: "spec-shard-red", always: "no")
    cli("lesson.record!", "kind.value=#{kind}", "signature.value=spec/a_spec.rb", "cause.value=A spec leans on another",
        "check.value=Run it in a shard", "fix.value=Require the constant", "always.value=#{always}")
  end

  def sighted(kind, run)
    cli("lesson.sighted!", "to=#{kind}", "kind.value=#{kind}", "sighting=#{kind}@#{run}", "run=#{run}", "commit=#{run}")
  end

  def sightings(kind) = JSON.parse(cli("sighting.of", "kind=#{kind}")).size

  it "counts a kind by the sightings recorded for it, one per run", :aggregate_failures do
    record
    sighted("spec-shard-red", "run-1")
    sighted("spec-shard-red", "run-2")
    expect(sightings("spec-shard-red")).to eq(2)
  end

  it "keeps the count of one kind apart from another" do
    record
    record(kind: "generated-output-not-regenerated")
    sighted("spec-shard-red", "run-1")
    expect(sightings("generated-output-not-regenerated")).to eq(0)
  end

  it "lists a lesson marked always in the always query" do
    record(always: "yes")
    expect(JSON.parse(cli("lesson.always")).map { |lesson| lesson["kind"] }).to eq(["spec-shard-red"])
  end

  it "leaves a lesson not marked always out of the always query" do
    record(always: "no")
    expect(JSON.parse(cli("lesson.always"))).to be_empty
  end

  it "records the check that now catches the kind when it is enforced" do
    record(always: "yes")
    cli("lesson.enforce!", "to=spec-shard-red", "kind.value=spec-shard-red", "enforced_by.value=spec/a_spec.rb gate")
    expect(JSON.parse(cli("lesson.always")).first["enforced_by"]).to eq("spec/a_spec.rb gate")
  end
end
