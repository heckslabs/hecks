require "hecks"
require_relative "fixtures/sequential_identity"

# A local boot, not `boot_in_memory` — Pizzas-specific by design. Same
# shape spec/governance_spec.rb already uses, plus the identity_generation
# port/adapter this domain's own Register command actually needs.
RSpec.describe "Identity" do
  def boot
    registry = Hecks::Runtime::Registry.new

    Hecks.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      Kernel.load(File.expand_path("../lib/hecks/ports/identity_generation.port", __dir__))
      Kernel.load(File.expand_path("fixtures/sequential_identity.adapter", __dir__))
      Kernel.load(File.join(InMemoryDomain::ROOT, "lib/hecks/framework/bluebook/identity.bluebook"))
      Hecks.hecksagon("Identity") do
        uses_framework "Governance"
        Identity::Identity.persisted_by("Memory")
        Identity::ExternalIdentifier.persisted_by("Memory")
      end
      Hecks.hecksagon("Governance") do
        Governance::RoleAssignment.persisted_by("Memory")
        Governance::RoleTransition.persisted_by("Memory")
      end
    end

    registry.verify!
    Hecks::Runtime::Loader.bind_runtime(Hecks::Runtime::Dispatcher.new(registry))
  end

  let(:runtime) { boot }

  def register
    Hecks::Adapters::SequentialIdentity.reset!
    minted = Hecks::Ports::IdentityGeneration.uuid(runtime.registry)
    runtime.dispatch("Identity::Identity.Register", identity_id: { value: minted })
  end

  it "registers an identity minted through the identity-generation port, not a natural key" do
    result = register

    expect(result.events.map(&:name)).to eq(["IdentityRegistered"])
    expect(result.instance.id).to eq("1")
  end

  it "links an external identifier to a real, previously-registered identity" do
    identity = register
    result = runtime.dispatch(
      "Identity::ExternalIdentifier.Link",
      identity: identity.instance.id,
      key: { value: "google:sub-1" }, issuer: { value: "google" }, subject: { value: "sub-1" }
    )

    expect(result.events.map(&:name)).to eq(["ExternalIdentifierLinked"])
    expect(result.instance.id).to eq("google:sub-1")
  end

  it "refuses to link an identifier to an identity that doesn't exist" do
    expect do
      runtime.dispatch(
        "Identity::ExternalIdentifier.Link",
        identity: "no-such-identity",
        key: { value: "google:sub-1" }, issuer: { value: "google" }, subject: { value: "sub-1" }
      )
    end.to raise_error(Hecks::Runtime::NotFound)
  end

  it "lets more than one external identifier link to the same identity" do
    identity = register
    google = runtime.dispatch(
      "Identity::ExternalIdentifier.Link",
      identity: identity.instance.id,
      key: { value: "google:sub-1" }, issuer: { value: "google" }, subject: { value: "sub-1" }
    )
    microsoft = runtime.dispatch(
      "Identity::ExternalIdentifier.Link",
      identity: identity.instance.id,
      key: { value: "microsoft:sub-1" }, issuer: { value: "microsoft" }, subject: { value: "sub-1" }
    )

    expect([google.instance.id, microsoft.instance.id]).to eq(["google:sub-1", "microsoft:sub-1"])
  end

  describe "ResolvedBy" do
    it "finds the identity an authenticated (issuer, subject) pair resolves to" do
      identity = register
      runtime.dispatch(
        "Identity::ExternalIdentifier.Link",
        identity: identity.instance.id,
        key: { value: "google:sub-1" }, issuer: { value: "google" }, subject: { value: "sub-1" }
      )

      rows = runtime.query(
        "Identity::ExternalIdentifier.ResolvedBy",
        issuer: { value: "google" }, subject: { value: "sub-1" }
      )

      expect(rows.map { |row| row[:identity] }).to eq([identity.instance.id])
    end

    it "answers empty for a pair nothing has linked" do
      rows = runtime.query(
        "Identity::ExternalIdentifier.ResolvedBy",
        issuer: { value: "google" }, subject: { value: "nobody" }
      )

      expect(rows).to be_empty
    end
  end
end
