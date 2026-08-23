require "spec_helper"

RSpec.describe "multi-field value-object identity at runtime" do
  def boot_identity_runtime
    registry = Hecksagain::Runtime::Registry.new

    Hecksagain.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)

      Hecks.bluebook "IdentityRuntime" do
        vision "the whole declared value concept identifies a transfer"

        aggregate "TransferInstruction" do
          value_object "TransferIdentity" do
            attribute :scheme, String, default: "ACH"
            attribute :end_to_end_id, String
            invariant("the end-to-end id is present") { end_to_end_id != "" }
          end

          identified_by TransferIdentity, as: :identity

          command "Register" do
            role "Operator"
            goal "Register one transfer instruction"
            attribute :identity, TransferIdentity
          end
        end
      end
    end

    registry.verify!
    Hecksagain::Runtime::Loader.bind_runtime(Hecksagain::Runtime::Dispatcher.new(registry))
  end

  it "coerces defaults and concatenates every member in declaration order" do
    runtime = boot_identity_runtime
    runtime.dispatch(
      "IdentityRuntime::TransferInstruction.Register",
      identity: { end_to_end_id: "e2e-42" }
    )

    aggregate = runtime.registry.bluebook("IdentityRuntime").aggregate("TransferInstruction")
    stored = runtime.registry.repository("IdentityRuntime", aggregate).find("ACH:e2e-42")

    expect(stored).not_to be_nil
    expect(stored[:identity].to_h).to eq(scheme: "ACH", end_to_end_id: "e2e-42")
  end

  it "does not reverse-split a joined identifier to invent structured state" do
    runtime = boot_identity_runtime
    aggregate = runtime.registry.bluebook("IdentityRuntime").aggregate("TransferInstruction")

    fresh = Hecksagain::Runtime::Instance.new(aggregate: aggregate, id: "ACH:e2e-42")

    expect(fresh[:identity]).to be_nil
  end

  it "refuses a blank required member before accepting the identity" do
    runtime = boot_identity_runtime

    expect do
      runtime.dispatch(
        "IdentityRuntime::TransferInstruction.Register",
        identity: { scheme: "ACH", end_to_end_id: "" }
      )
    end.to raise_error(Hecksagain::Runtime::InvariantViolation, /end-to-end id is present/)
  end
end
