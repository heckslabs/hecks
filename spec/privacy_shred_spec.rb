require "spec_helper"

# A shred is a request the key vault answers (ADR 0142): the record reads `shredded` only after
# the vault destroyed the key, and a vault that refuses leaves the key live and the shred retryable.
RSpec.describe "shredding a subject's key" do
  VAULT = Hecks::Adapters::InProcessKeyVault
  SUBJECT = { domain: { value: "Studio::Registration" }, subject_id: { value: "attendee-482" } }.freeze

  def boot_privacy
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) do
      MemoryPorts.load!
      Kernel.load(File.join(InMemoryDomain::ROOT, "lib/hecks/ports/key_vault.port"))
      Kernel.load(File.join(InMemoryDomain::ROOT, "lib/hecks/adapters/driven/in_process_key_vault.adapter"))
      Hecks::Framework.load!("Privacy")
      declare_wiring
    end
    registry.verify!
    Hecks::Runtime::Loader.bind_runtime(Hecks::Runtime::Dispatcher.new(registry))
  end

  def declare_wiring
    Hecks.hecksagon("Privacy") do
      attaches "Governance"
      Privacy::SubjectKey.persisted_by("Memory")
      Privacy::Marking.persisted_by("Memory")
    end
    Hecks.hecksagon("Governance") do
      Governance::RoleAssignment.persisted_by("Memory")
      Governance::RoleTransition.persisted_by("Memory")
    end
  end

  def issue_key(runtime)
    reference = Hecks::Ports::KeyVault.issue(runtime.registry, subject_id: "attendee-482")
    runtime.dispatch_flat("Privacy::SubjectKey.Issue", SUBJECT.merge(key_reference: { value: reference }))
    reference
  end

  def record(runtime) = runtime.query("Privacy::SubjectKey.ForSubject", **SUBJECT).first

  def shred(runtime)
    Hecks::Ports::KeyVault.shred!(runtime, domain: "Studio::Registration", subject_id: "attendee-482")
  end

  def recent_events(runtime) = runtime.registry.event_log.map(&:name).last(3)

  def vault_unavailable = allow(VAULT).to receive(:destroy).and_raise(RuntimeError, "vault unavailable")

  def mark_shredded_by_hand(runtime, reference)
    Hecks.as_caller(role: "Privacy officer") do
      runtime.dispatch_flat("Privacy::SubjectKey.MarkShredded", SUBJECT.merge(key_reference: { value: reference }))
    end
  end

  before { VAULT.reset! }

  let(:runtime) { boot_privacy }
  let!(:reference) { issue_key(runtime) }

  it "records the shred only after the vault destroyed the key", :aggregate_failures do
    expect(shred(runtime)).to be(true)
    expect([record(runtime)[:status], VAULT.fetch(reference)]).to eq(["shredded", nil])
    expect(recent_events(runtime)).to eq(%w[SubjectKeyShredRequested SubjectKeyDestroyed SubjectKeyShredded])
  end

  it "leaves the key live and the record shred_failed when the vault refuses", :aggregate_failures do
    vault_unavailable
    shred(runtime)
    expect(record(runtime)[:status]).to eq("shred_failed")
    expect(record(runtime)[:refusal].value).to include("vault unavailable")
    expect(VAULT.fetch(reference)).to be_a(String)
  end

  it "shreds again from shred_failed once the vault answers", :aggregate_failures do
    vault_unavailable
    shred(runtime)
    allow(VAULT).to receive(:destroy).and_call_original
    expect(shred(runtime)).to be(true)
    expect([record(runtime)[:status], VAULT.fetch(reference)]).to eq(["shredded", nil])
  end

  it "leaves a subject already shredded alone" do
    shred(runtime)
    expect(shred(runtime)).to be(false)
  end

  it "refuses a privacy officer who marks a shred done by hand" do
    expect { mark_shredded_by_hand(runtime, reference) }.to raise_error(Hecks::Refused, /Unauthorized|role/i)
  end
end
