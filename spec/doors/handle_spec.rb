require "spec_helper"
require "tempfile"

RSpec.describe Hecks::Doors::Handle do
  BANKING_BLUEBOOK = InMemoryDomain::BANKING_BLUEBOOK_DIR unless defined?(BANKING_BLUEBOOK)

  def boot_banking_in_memory
    registry = Hecks::Runtime::Registry.new

    Hecks.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      load_bluebook_files(BANKING_BLUEBOOK)

      Hecks.hecksagon("Banking") do
        uses_framework "Governance"
        Banking::Customer.persisted_by("Memory")
        Banking::Account.persisted_by("Memory")
        Banking::SafeDepositBox.persisted_by("Memory")
      end
      Hecks.hecksagon("Governance") do
        Governance::RoleAssignment.persisted_by("Memory")
        Governance::RoleTransition.persisted_by("Memory")
      end
    end

    registry.verify!
    Hecks::Runtime::Loader.bind_runtime(Hecks::Runtime::Dispatcher.new(registry))
  end

  # A verb whose snake-cased name collides with an Object/Kernel method (`Freeze`,
  # `Send`) must dispatch, not be swallowed by the Kernel method. No shipped chapter
  # collides, so this chapter exists only to.
  def boot_collider
    registry = Hecks::Runtime::Registry.new

    Hecks.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)

      Hecks.bluebook "Collider" do
        aggregate "Vault" do
          attribute :tag, Tag

          identified_by :tag

          value_object("Tag") { attribute :value, String }

          lifecycle :status, default: "open" do
            transition "Freeze" => "frozen", from: "open"
            transition "Send"   => "sent",   from: "frozen"
            transition "Thaw"   => "open",   from: "frozen"
          end

          command "Build" do
            attribute :tag, Tag
            sets :tag
            emits "VaultBuilt"
          end

          # Each snake-cases onto a real Object/Kernel method.
          command("Freeze") do
            reference_to Vault
            emits "VaultFrozen"
          end
          command("Send") do
            reference_to Vault
            emits "VaultSent"
          end
          command("Thaw") do
            reference_to Vault
            emits "VaultThawed"
          end
        end
      end

      Hecks.hecksagon("Collider") { Collider::Vault.persisted_by("Memory") }
    end

    registry.verify!
    Hecks::Runtime::Loader.bind_runtime(Hecks::Runtime::Dispatcher.new(registry))
  end

  it "dispatches a verb even when its name collides with a Kernel method" do
    boot_collider

    vault = Collider::Vault.build!(tag: { value: "v1" })
    expect(vault.status).to eq("open")

    vault.freeze!

    expect(vault.status).to eq("frozen")
    # The domain verb ran; the object is not Kernel-frozen.
    expect(vault.frozen?).to be(false)
    expect(vault.events.map(&:name)).to include("VaultFrozen")

    # `send` is the sharper case: Kernel#send would invoke another method.
    vault.send!

    expect(vault.status).to eq("sent")
    expect(vault.events.map(&:name)).to include("VaultSent")
  end

  it "chains a colliding verb the way every other non-creating verb chains" do
    boot_collider

    vault = Collider::Vault.build!(tag: { value: "v2" })
    vault.freeze!
    # A Kernel-frozen object would raise FrozenError when `run` reassigns @state.
    vault.thaw!

    expect(vault.status).to eq("open")
  end

  # `identified_by` is nil for a composite identity, so addressing by it would build
  # `{ nil => @id }`. SafeDepositBox is the corpus's one composite-identity head.
  it "dispatches non-creating verbs on a composite-identity aggregate" do
    boot_banking_in_memory

    Banking::Customer.register!(reference: { value: "c1" }, name: { given: "Ada", family: "Lovelace" },
                                email: { address: "ada@example.com" })
    box = Banking::SafeDepositBox.rent!(customer: "c1", branch_code: { value: "BR01" },
                                        box_number: { value: 12 }, size: { value: "small" })

    box.log_visit!(date: { value: "2026-08-04" }, sequence: { value: 1 })
    expect(box[:visits].size).to eq(1)

    box.issue_key!(serial: { value: "K1" })
    expect(box[:keys].size).to eq(1)

    # Zero declared attributes: the identity payload is the whole args hash.
    box.surrender!
    expect(box.status).to eq("vacant")
  end

  # An attribute literally named `id` must not clobber the bare identity in `to_h`
  # with its wrapped value. `Thingy::Thing` exists only to declare one.
  def boot_thingy
    registry = Hecks::Runtime::Registry.new
    source = <<~BLUEBOOK
      Hecks.bluebook "Thingy" do
        aggregate "Thing" do
          identified_by :id

          value_object "ThingId" do
            attribute :value, String
          end

          value_object "ThingName" do
            attribute :value, String
          end

          attribute :id,   ThingId
          attribute :name, ThingName

          command "Mint" do
            attribute :id,   ThingId
            attribute :name, ThingName
            emits "Minted"
          end
        end
      end
    BLUEBOOK
    file = Tempfile.new(["thing-", ".bluebook"])
    file.write(source)
    file.flush

    Hecks.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      Kernel.eval(source, TOPLEVEL_BINDING, file.path, 1)

      Hecks.hecksagon("Thingy") do
        Thingy::Thing.persisted_by("Memory")
      end
    end

    registry.verify!
    Hecks::Runtime::Loader.bind_runtime(Hecks::Runtime::Dispatcher.new(registry))
  ensure
    file&.close!
  end

  it "keeps a declared attribute literally named id from clobbering the bare identity in to_h" do
    boot_thingy

    thing = Thingy::Thing.mint!(id: { value: "t1" }, name: { value: "goggles" })

    expect(thing.id).to eq("t1")
    expect(thing.to_h[:id]).to eq("t1")

    # Only `:id` is unwrapped; other attributes stay a `Runtime::Value`.
    expect(thing.to_h[:name]).to be_a(Hecks::Runtime::Value)
    expect(thing.to_h[:name].to_h).to eq({ value: "goggles" })
  end
end
