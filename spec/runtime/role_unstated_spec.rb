require "spec_helper"

# ADR 0216 in shadow: a role-gated command whose caller states no role still runs in the
# runtime, and the would-refuse is recorded; the Storehouse door refuses it, in the same words
# the runtime will use once refusing is the default. The domain is shaped like miette_tools,
# where `Proposal.Approve` ran from the CLI with no role. Shadow says nothing on stderr: every
# meta-domain reaction would print a line at each boot, so the count is what is checked.
RSpec.describe "a role-gated command dispatched by a caller who states no role" do
  ROLE_UNSTATED_DOMAIN = proc do
    vision "A proposal, submitted, reviewed by the system and approved by the owner."

    aggregate "Proposal" do
      value_object "Ref", String
      identified_by :ref
      attribute :ref, Ref

      command "Submit" do
        attribute :ref, Ref
        sets :ref
        emits "ProposalSubmitted"
      end

      command "Review" do
        role "Reviewer"
        reference_to Proposal
        emits "ProposalReviewed"
      end

      command "Approve" do
        role "Owner"
        reference_to Proposal
        emits "ProposalApproved"
      end
    end

    policy "ReviewOnSubmit" do
      on      "ProposalSubmitted"
      trigger Proposal::Review
    end
  end

  def build
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) do
      MemoryPorts.load!
      Hecks.bluebook("MietteTools", &ROLE_UNSTATED_DOMAIN)
      Kernel.load(File.expand_path("../../lib/hecks/ports/authorization.port", __dir__))
      Kernel.load(File.expand_path("../../lib/hecks/adapters/driven/governance_authorization.adapter", __dir__))
      bind_hecksagons
    end
    registry.verify!
    Hecks::Runtime::Loader.bind_runtime(Hecks::Runtime::Dispatcher.new(registry))
  end

  def bind_hecksagons
    Hecks.hecksagon("MietteTools") do
      attaches "Governance"
      MietteTools::Proposal.persisted_by("Memory")
    end
    sibling_governance!
  end

  def submitted(ref = "p1") = MietteTools::Proposal.submit!(ref: { value: ref })

  def approve_unbound = submitted.approve!

  def unstated_log(runtime) = runtime.registry.unstated_caller_log

  def door_approve(runtime)
    submitted
    Hecks::Storehouse.dispatch(runtime: runtime, command: "proposal.approve", summary: "spec", args: { proposal: "p1" })
  end

  it "lets an unbound Proposal.Approve run in shadow and counts the would-refuse", :aggregate_failures do
    runtime = build
    approve_unbound
    expect(MietteTools::Proposal.find("p1").events.map(&:name)).to include("ProposalApproved")
    expect(unstated_log(runtime)).to include(%w[MietteTools Approve unstated] => 1)
  end

  it "counts each unbound run of the same command under one key" do
    runtime = build
    [approve_unbound, submitted("p2").approve!]
    expect(unstated_log(runtime)).to include(%w[MietteTools Approve unstated] => 2)
  end

  it "records a policy's unbound dispatch of a role-gated command as a reaction" do
    runtime = build
    submitted
    expect(unstated_log(runtime)).to include(%w[MietteTools Review reaction] => 1)
  end

  it "still refuses a caller who states a role the command does not declare" do
    build
    proposal = submitted
    expect { Hecks.as_caller(role: "Agent") { proposal.approve! } }
      .to raise_error(Hecks::Runtime::Unauthorized, /Approve refused — role: Owner, and the caller stated Agent/)
  end

  it "refuses Proposal.Approve at the Storehouse door in the role_unstated wording" do
    wording = Hecks::Runtime::RefusalWording.render_site("Unauthorized", "role_unstated", command: "Approve", role: "Owner")
    expect(door_approve(build).to_s).to include(wording)
  end
end
