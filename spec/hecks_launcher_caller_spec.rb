require "spec_helper"

# Who a line of the Hecks launcher dispatches as (ADR 0216): a line that states no `--as` runs as
# the first role the Hecks world's `caller_roles` lists that its command declares, so the
# pipeline's own system steps run; an owner's command is refused until the line states the role.
RSpec.describe "the Hecks launcher's caller" do
  before(:all) do
    @hecks = boot_hecks_in_memory
  end

  def launch(*argv) = Hecks::Adapters::Driving::CliRunner.call(runtime: @hecks, argv: argv, program: "hecks")

  def assign(*caller)
    launch("RoleAssignment.assign!", *caller, "actor_id.value=ada", "role_name.value=Maintainer",
           "scope.value=hecks", "starts_at.value=2026-11-27T00:00:00Z")
  end

  def await_review
    launch("LandingReview.await!", "tip.value=c1", "run.value=run-c1", "checkout.value=/scratch/c1", "branch.value=w-c1",
           "brief.value=build it", "confirm.value=true", "mode.value=enforce", "--wait")
  end

  it "runs a system step that states no role as the System its command declares" do
    expect(await_review.last).to eq(0)
  end

  it "refuses an owner's command that states no role, naming the command and its role" do
    expect(assign.first).to eq("[unauthorized] Assign refused — role: Governance administrator, and the caller stated no role")
  end

  it "runs an owner's command when the line states the owner's role" do
    expect(assign("--as", "Governance administrator").last).to eq(0)
  end
end
