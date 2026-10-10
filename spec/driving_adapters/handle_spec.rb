require "spec_helper"
require "tempfile"
require_relative "../support/memory_ports"

RSpec.describe Hecks::Adapters::Driving::Handle do
  BANKING_BLUEBOOK = InMemoryDomain::BANKING_BLUEBOOK_DIR unless defined?(BANKING_BLUEBOOK)

  # A verb whose snake-cased name collides with an Object/Kernel method (`Freeze`,
  # `Send`) must dispatch, not be swallowed by the Kernel method. No shipped chapter
  # collides, so this chapter exists only to.
  COLLIDER_SOURCE = <<~BLUEBOOK.freeze
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
  BLUEBOOK

  # An attribute literally named `id` must not clobber the bare identity in `to_h`
  # with its wrapped value. `Thingy::Thing` exists only to declare one.
  THINGY_SOURCE = <<~BLUEBOOK.freeze
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

  # Boots a fresh registry on the Memory adapter, runs the block to declare the domain,
  # then verifies it and binds the runtime.
  def boot_with_memory
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) do
      MemoryPorts.load!
      yield
    end
    registry.verify!
    Hecks::Runtime::Loader.bind_runtime(Hecks::Runtime::Dispatcher.new(registry))
  end

  # Boots a domain declared by a bluebook source, evaluated from a file of its own.
  def boot_source(source)
    file = Tempfile.new(["domain-", ".bluebook"])
    file.write(source)
    file.flush
    boot_with_memory do
      Kernel.eval(source, TOPLEVEL_BINDING, file.path, 1)
      yield
    end
  ensure
    file&.close!
  end

  def boot_banking_in_memory
    boot_with_memory do
      load_bluebook_files(BANKING_BLUEBOOK)
      Hecks.hecksagon("Banking") do
        attaches "Governance"
        Banking::Customer.persisted_by("Memory")
        Banking::Account.persisted_by("Memory")
        Banking::SafeDepositBox.persisted_by("Memory")
      end
      sibling_governance!
    end
  end

  def boot_collider
    boot_source(COLLIDER_SOURCE) { Hecks.hecksagon("Collider") { Collider::Vault.persisted_by("Memory") } }
  end

  def boot_thingy
    boot_source(THINGY_SOURCE) { Hecks.hecksagon("Thingy") { Thingy::Thing.persisted_by("Memory") } }
  end

  def vault_for(tag)
    boot_collider
    Collider::Vault.build!(tag: { value: tag })
  end

  def rented_box
    boot_banking_in_memory
    Banking::Customer.register!(reference: { value: "c1" }, name: { given: "Ada", family: "Lovelace" },
                                email: { address: "ada@example.com" })
    Banking::SafeDepositBox.rent!(customer: "c1", branch_code: { value: "BR01" },
                                  box_number: { value: 12 }, size: { value: "small" })
  end

  def minted_thing
    boot_thingy
    Thingy::Thing.mint!(id: { value: "t1" }, name: { value: "goggles" })
  end

  it "builds a vault in its opening state" do
    expect(vault_for("v0").status).to eq("open")
  end

  it "dispatches a verb even when its name collides with a Kernel method", :aggregate_failures do
    vault = vault_for("v1")
    vault.freeze!

    expect(vault.status).to eq("frozen")
    # The domain verb ran; the object is not Kernel-frozen.
    expect(vault.frozen?).to be(false)
    expect(vault.events.map(&:name)).to include("VaultFrozen")
  end

  # `send` is the sharper case: Kernel#send would invoke another method.
  it "dispatches a verb named send rather than Kernel#send", :aggregate_failures do
    vault = vault_for("v1")
    vault.freeze!
    vault.send!

    expect(vault.status).to eq("sent")
    expect(vault.events.map(&:name)).to include("VaultSent")
  end

  it "chains a colliding verb the way every other non-creating verb chains" do
    vault = vault_for("v2")
    vault.freeze!
    # A Kernel-frozen object would raise FrozenError when `run` reassigns @state.
    vault.thaw!

    expect(vault.status).to eq("open")
  end

  # `identified_by` is nil for a composite identity, so addressing by it would build
  # `{ nil => @id }`. SafeDepositBox is the corpus's one composite-identity head.
  describe "non-creating verbs on a composite-identity aggregate" do
    it "dispatches a verb that adds a child" do
      box = rented_box
      box.log_visit!(date: { value: "2026-08-04" }, sequence: { value: 1 })

      expect(box[:visits].size).to eq(1)
    end

    it "dispatches a verb that adds a second kind of child" do
      box = rented_box
      box.issue_key!(serial: { value: "K1" })

      expect(box[:keys].size).to eq(1)
    end

    # Zero declared attributes: the identity payload is the whole args hash.
    it "dispatches a verb that declares no attributes" do
      box = rented_box
      box.surrender!

      expect(box.status).to eq("vacant")
    end
  end

  it "keeps a declared attribute literally named id from clobbering the bare identity in to_h", :aggregate_failures do
    thing = minted_thing

    expect(thing.id).to eq("t1")
    expect(thing.to_h[:id]).to eq("t1")
    # Only `:id` is unwrapped; other attributes stay a `Runtime::Value`.
    expect(thing.to_h[:name]).to be_a(Hecks::Runtime::Value)
    expect(thing.to_h[:name].to_h).to eq({ value: "goggles" })
  end
end
