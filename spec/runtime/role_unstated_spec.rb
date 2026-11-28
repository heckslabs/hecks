require "spec_helper"

# ADR 0216: a role-gated command refuses the outside caller who states no role (`Caller.unstated`,
# which a door binds), in the same words at the Storehouse door, and a policy's reaction that
# declares no `acts_as` is that caller too in a cascade a caller began. A dispatch with no caller
# bound is the process acting for itself and runs, counted. The domain is shaped like
# miette_tools, where `Proposal.Approve` ran from the CLI with no role.
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

  def unstated_approve = Hecks::Runtime::Caller.unstated { submitted.approve! }

  def in_mode(mode)
    Hecks::Runtime::RoleShadow.install(mode)
    yield
  ensure
    Hecks::Runtime::RoleShadow.install(Hecks::Runtime::RoleShadow::DEFAULT)
  end

  it "refuses Proposal.Approve from a caller who states no role, naming the command and its role" do
    build
    expect { unstated_approve }
      .to raise_error(Hecks::Runtime::Unauthorized, "Approve refused — role: Owner, and the caller stated no role")
  end

  it "lets the unstated caller through under shadow and counts the would-refuse" do
    runtime = build
    in_mode(:shadow) { unstated_approve }
    expect(unstated_log(runtime)).to include(%w[MietteTools Approve unstated] => 1)
  end

  it "runs a dispatch with no caller bound, as the process acting for itself, and counts it" do
    runtime = build
    [approve_unbound, submitted("p2").approve!]
    expect(unstated_log(runtime)).to include(%w[MietteTools Approve internal] => 2)
  end

  it "refuses an undeclared policy's reaction in a cascade a caller began, in the role_unstated wording" do
    runtime = build
    Hecks.as_caller(role: "Owner") { submitted }
    expect(runtime.reactions.first[:reason]).to include("Review refused — role: Reviewer, and the caller stated no role")
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
