require "spec_helper"

# `validate` and `dry_run?` are two entry points to one pipeline, so the property holds them to the
# same verdict on every dry-run step the fuzzer replays.
RSpec.describe "the validation_agrees_with_dry_run property" do
  def check(*traces) = Hecks::Fuzzing::Properties.validation_agrees_with_dry_run(dry_run_traces: traces)

  def trace(verb: "A::B.C", accepted: true, error: nil, **validation)
    { verb: verb, ok: accepted, error: error,
validation: { ok: accepted, first_stage: nil, first_message: error }.merge(validation) }
  end

  it "passes when both accept a command" do
    expect(check(trace)).to be(true)
  end

  it "passes when both refuse it for the same first reason" do
    expect(check(trace(accepted: false, error: "A refused - the flow is positive", first_stage: :givens))).to be(true)
  end

  it "names a command one accepts and the other refuses" do
    entry = trace.merge(validation: { ok: false, first_stage: :givens, first_message: "no" })

    expect(check(entry)).to include("A::B.C: dry_run? ok=true, validate ok=false")
  end

  it "names a first refusal that is not the one the dry run raised" do
    entry = trace(accepted: false, error: "unknown argument bogus", first_stage: :arguments, first_message: "absent flow")

    expect(check(entry)).to include("dry_run? raised \"unknown argument bogus\"")
  end

  it "does not hold a role refusal to what the dry run raised, since validate checks the role first" do
    entry = trace(accepted: false, error: "unknown argument bogus", first_stage: :role, first_message: "needs Teller")

    expect(check(entry)).to be(true)
  end

  it "holds a refusal validate split per offender to the dry run's class and first offender" do
    offender = ["Hecks::Runtime::UnknownArgument", :note]
    entry = trace(accepted: false, error: "Open does not declare note, rank", first_stage: :arguments,
                  first_message: "Open does not declare note", first_offender: offender).merge(raised: offender)

    expect(check(entry)).to be(true)
  end

  it "names a split refusal whose first offender is not the dry run's" do
    entry = trace(accepted: false, error: "Open does not declare note, rank", first_stage: :arguments,
                  first_message: "Open does not declare rank",
                  first_offender: ["Hecks::Runtime::UnknownArgument", :rank])
            .merge(raised: ["Hecks::Runtime::UnknownArgument", :note])

    expect(check(entry)).to include("validate's first was \"Open does not declare rank\"")
  end

  it "makes no claim about a step with no validation recorded" do
    expect(check({ verb: "A::B.C", ok: true })).to be(true)
  end
end
