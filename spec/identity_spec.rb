require "hecks"
require_relative "fixtures/sequential_identity"

# A local boot, not `boot_in_memory` — Pizzas-specific by design. Same
# shape spec/governance_spec.rb already uses, plus the identity_generation
# port/adapter this domain's own Register command actually needs.
RSpec.describe "Identity" do
  IDENTITY_SPEC_FILES = [
    InMemoryDomain::PERSISTENCE_PORT, InMemoryDomain::EXTRACTION_PORT,
    InMemoryDomain::MEMORY_ADAPTER, InMemoryDomain::PRISM_ADAPTER,
    File.expand_path("../lib/hecks/ports/identity_generation.port", __dir__),
    File.expand_path("fixtures/sequential_identity.adapter", __dir__),
    File.join(InMemoryDomain::ROOT, "lib/hecks/framework/bluebook/identity.bluebook")
  ].freeze

  def declare_identity_hecksagons
    Hecks.hecksagon("Identity") do
      attaches "Governance"
      Identity::Identity.persisted_by("Memory")
      Identity::ExternalIdentifier.persisted_by("Memory")
    end
    Hecks.hecksagon("Governance") do
      Governance::RoleAssignment.persisted_by("Memory")
      Governance::RoleTransition.persisted_by("Memory")
    end
  end

  def boot
    registry = Hecks::Runtime::Registry.new

    Hecks.with_registry(registry) do
      IDENTITY_SPEC_FILES.each { |file| Kernel.load(file) }
      declare_identity_hecksagons
    end

    registry.verify!
    Hecks::Runtime::Loader.bind_runtime(Hecks::Runtime::Dispatcher.new(registry))
  end

  let(:runtime) { boot }

  def register
    Hecks::Adapters::SequentialIdentity.reset!
    minted = Hecks::Ports::IdentityGeneration.uuid(runtime.registry)
    runtime.dispatch_flat("Identity::Identity.Register", identity_id: { value: minted })
  end

  # Links the external identifier `issuer:subject` to the identity with id `identity_id`.
  def link(identity_id, issuer:, subject:)
    runtime.dispatch_flat("Identity::ExternalIdentifier.Link", identity: identity_id, key: { value: "#{issuer}:#{subject}" },
                                                              issuer: { value: issuer }, subject: { value: subject })
  end

  # The rows `ResolvedBy` answers for an (issuer, subject) pair.
  def resolved_by(issuer, subject)
    runtime.query("Identity::ExternalIdentifier.ResolvedBy", issuer: { value: issuer }, subject: { value: subject })
  end

  it "registers an identity minted through the identity-generation port, not a natural key", :aggregate_failures do
    result = register

    expect(result.events.map(&:name)).to eq(["IdentityRegistered"])
    expect(result.instance.id).to eq("1")
  end

  it "links an external identifier to a real, previously-registered identity", :aggregate_failures do
    identity = register
    result = link(identity.instance.id, issuer: "google", subject: "sub-1")

    expect(result.events.map(&:name)).to eq(["ExternalIdentifierLinked"])
    expect(result.instance.id).to eq("google:sub-1")
  end

  it "refuses to link an identifier to an identity that doesn't exist" do
    expect { link("no-such-identity", issuer: "google", subject: "sub-1") }.to raise_error(Hecks::Runtime::NotFound)
  end

  it "lets more than one external identifier link to the same identity" do
    identity = register
    google = link(identity.instance.id, issuer: "google", subject: "sub-1")
    microsoft = link(identity.instance.id, issuer: "microsoft", subject: "sub-1")

    expect([google.instance.id, microsoft.instance.id]).to eq(["google:sub-1", "microsoft:sub-1"])
  end

  describe "ResolvedBy" do
    it "finds the identity an authenticated (issuer, subject) pair resolves to" do
      identity = register
      link(identity.instance.id, issuer: "google", subject: "sub-1")

      expect(resolved_by("google", "sub-1").map { |row| row[:identity] }).to eq([identity.instance.id])
    end

    it "answers empty for a pair nothing has linked" do
      expect(resolved_by("google", "nobody")).to be_empty
    end
  end
end
