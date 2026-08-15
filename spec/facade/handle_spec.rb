require "spec_helper"
require "tempfile"

RSpec.describe Hecksagain::Facade::Handle do
  BANKING_BLUEBOOK = File.join(InMemoryDomain::ROOT, "examples/banking/bluebook/banking.bluebook")

  def boot_banking_in_memory
    registry = Hecksagain::Runtime::Registry.new

    Hecksagain.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      Kernel.load(BANKING_BLUEBOOK)

      Hecks.hecksagon("Banking") do
        uses_framework "Governance"
        ::Banking::Customer.persisted_by("Memory")
        ::Banking::Account.persisted_by("Memory")
        ::Banking::SafeDepositBox.persisted_by("Memory")
      end
      Hecks.hecksagon("Governance") do
        ::Governance::RoleAssignment.persisted_by("Memory")
        ::Governance::RoleTransition.persisted_by("Memory")
      end
    end

    registry.verify!
    Hecksagain::Runtime::Loader.bind_runtime(Hecksagain::Runtime::Dispatcher.new(registry))
  end

  # A non-creating verb whose snake-cased name collides with a real
  # Object/Kernel method (`Freeze` -> `freeze`, `Send` -> `send`) used to
  # be silently swallowed by the Kernel method rather than dispatched — no
  # error, no refusal, the transition just never happened.
  #
  # THE FIXTURE IS DELIBERATE, not a convenience. Banking used to be the
  # subject here (`Account.Freeze`, `ExternalTransfer.Send` were the only
  # two colliding verbs in the whole corpus) and both were renamed —
  # domain vocabulary should not be chosen by what Ruby happens to have
  # taken. That leaves nothing shipped to prove this with, and the
  # protection is for somebody ELSE'S domain now : anyone is still free to
  # name a command `Freeze`, so the guard has to keep being tested. A
  # chapter that exists only to collide is the honest way to do that.
  def boot_collider
    registry = Hecksagain::Runtime::Registry.new

    Hecksagain.with_registry(registry) do
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

          # Every one of these snake-cases onto a real Object/Kernel
          # method, which is the entire point.
          command("Freeze")  { reference_to Vault; emits "VaultFrozen" }
          command("Send")    { reference_to Vault; emits "VaultSent" }
          command("Thaw")    { reference_to Vault; emits "VaultThawed" }
        end
      end

      Hecks.hecksagon("Collider") { ::Collider::Vault.persisted_by("Memory") }
    end

    registry.verify!
    Hecksagain::Runtime::Loader.bind_runtime(Hecksagain::Runtime::Dispatcher.new(registry))
  end

  it "dispatches a verb even when its name collides with a Kernel method" do
    boot_collider

    vault = Collider::Vault.build(tag: { value: "v1" })
    expect(vault.status).to eq("open")

    vault.freeze

    expect(vault.status).to eq("frozen")
    # NOT actually Kernel-frozen — the domain verb ran, the object did not
    # become immutable.
    expect(vault.frozen?).to be(false)
    expect(vault.events.map(&:name)).to include("VaultFrozen")

    # `send` is the sharper case: Kernel#send takes a method name and would
    # happily invoke something else entirely rather than refuse.
    vault.send

    expect(vault.status).to eq("sent")
    expect(vault.events.map(&:name)).to include("VaultSent")
  end

  it "chains a colliding verb the way every other non-creating verb chains" do
    boot_collider

    vault = Collider::Vault.build(tag: { value: "v2" })
    vault.freeze
    # A truly Kernel-frozen object would raise FrozenError the moment `run`
    # tried to reassign @state.
    vault.thaw

    expect(vault.status).to eq("open")
  end

  # `Handle#run` used to address every non-creating verb with
  # `{ @ir.identified_by => @id }` — `identified_by` is nil the moment an
  # identity is composite, so this built `{ nil => @id }`, and dispatch's
  # own argument gate crashed on `nil.to_sym` reading the args back (worse
  # still on a zero-attribute command like `Surrender`, where that stray nil
  # key was the ONLY thing in the payload). `SafeDepositBox`'s
  # `branch_code`/`box_number` identity is banking's one composite head,
  # so it is what proves door sugar addresses a multi-part identity, not
  # just a single one.
  it "dispatches non-creating verbs on a composite-identity aggregate" do
    boot_banking_in_memory

    Banking::Customer.register(reference: { value: "c1" }, name: { given: "Ada", family: "Lovelace" },
                                email: { address: "ada@example.com" })
    box = Banking::SafeDepositBox.rent(customer: "c1", branch_code: { value: "BR01" },
                                        box_number: { value: 12 }, size: { value: "small" })

    box.log_visit(date: { value: "2026-08-04" }, sequence: { value: 1 })
    expect(box[:visits].size).to eq(1)

    box.issue_key(serial: { value: "K1" })
    expect(box[:keys].size).to eq(1)

    # Zero declared attributes — the identity payload is the ENTIRE args
    # hash, so a stray `nil` key had nowhere to hide.
    box.surrender
    expect(box.status).to eq("vacant")
  end

  # `to_h` used to be `{ id: @id }.merge(@state)` — `@state` merged LAST,
  # so an aggregate free to declare its own attribute literally named `id`
  # (real corpus now: BurningManPrep's `Item`, `attribute :id, ItemId`,
  # `identified_by :id`) got that attribute's own WRAPPED value
  # object silently clobbering the correctly-unwrapped bare `@id`. The
  # JSON door's own `/api/:coll` listing is the caller that actually hit
  # this: every record's own `id` key came back `{value: "..."}` instead
  # of a bare string, which collapsed an entire collection's own client-
  # side id-keyed cache down to one entry (every wrapped-hash key stringifies
  # the same way).
  it "keeps a declared attribute literally named id from clobbering the bare identity in to_h" do
    registry = Hecksagain::Runtime::Registry.new
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

    Hecksagain.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      Kernel.eval(source, TOPLEVEL_BINDING, file.path, 1)

      Hecks.hecksagon("Thingy") do
        ::Thingy::Thing.persisted_by("Memory")
      end
    end

    registry.verify!
    Hecksagain::Runtime::Loader.bind_runtime(Hecksagain::Runtime::Dispatcher.new(registry))

    thing = Thingy::Thing.mint(id: { value: "t1" }, name: { value: "goggles" })

    expect(thing.id).to eq("t1")
    expect(thing.to_h[:id]).to eq("t1")

    # Scope check: this fix is about `:id` specifically clobbering itself,
    # not a general re-unwrap of every field — an ordinary declared
    # attribute stays exactly what it always was, a `Runtime::Value`.
    expect(thing.to_h[:name]).to be_a(Hecksagain::Runtime::Value)
    expect(thing.to_h[:name].to_h).to eq({ value: "goggles" })
  ensure
    file&.close!
  end
end
