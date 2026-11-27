require "spec_helper"
require "tmpdir"

# A shop whose placed order owes its Ledger a Record: the policy is the delivery read back.
module OutboxDeliveryShop
  BLUEBOOK = <<~RUBY.freeze
    Hecks.bluebook "Shop" do
      vision "An order placed is an order remembered."
      core

      aggregate "Order" do
        value_object("Number") { attribute :value, String }
        attribute :number, Number
        identified_by :number

        command "Place" do
          attribute :number, Number
          sets :number
          emits "OrderPlaced"
        end
      end

      aggregate "Ledger" do
        value_object("Number") { attribute :value, String }
        attribute :number, Number
        identified_by :number

        command "Record" do
          attribute :number, Number
          sets :number
          emits "OrderRecorded"
        end
      end

      policy "RecordOrder" do
        on "OrderPlaced"
        trigger Ledger::Record, with: { number: :number }
      end
    end
  RUBY

  # The members the shop attaches, each bound to Memory; EventDelivery's roles need Governance.
  SIBLINGS = <<~RUBY.freeze
    Hecks.hecksagon "Governance" do
      persisted_by "Memory"
    end

    Hecks.hecksagon "EventDelivery" do
      attaches "Governance"
      persisted_by "Memory"
    end
  RUBY
end

# A domain that attaches EventDelivery reads its deliveries through the `event_delivery` port,
# which the Ruby outbox answers (ADR 0178): each outbox row comes back as a `Delivery`, and a
# dispatch a store has claimed comes back as answered.
RSpec.describe "the outbox as EventDelivery's adapter" do
  around do |example|
    Dir.mktmpdir("hecks-outbox-delivery-") do |dir|
      @dir = dir
      example.run
    end
  end

  def write_shop(attaches:, adapter:)
    File.write(File.join(@dir, "shop.bluebook"), OutboxDeliveryShop::BLUEBOOK)
    File.write(File.join(@dir, "shop.hecksagon"), <<~RUBY)
      Hecks.hecksagon "Shop" do
        #{attaches.map { |name| "attaches #{name.inspect}" }.join("\n  ")}
        persisted_by #{adapter.inspect}
      end
    RUBY
    File.write(File.join(@dir, "context_map.hecksagon"), OutboxDeliveryShop::SIBLINGS) unless attaches.empty?
  end

  def boot(attaches: %w[Governance EventDelivery], adapter: "Memory")
    write_shop(attaches: attaches, adapter: adapter)
    if adapter == "SqlitePersistence"
      File.write(File.join(@dir, "shop.world"),
                 "Hecks.world \"Shop\" do\n  default_adapter \"SqlitePersistence\"\n  " \
                 "default_database #{File.join(@dir, "shop.db").inspect}\nend\n")
    end
    Hecks.boot(@dir, install_driving: false)
  end

  def place(runtime) = runtime.dispatch("Shop::Order.Place", with: { number: { value: "o-1" } })

  def deliveries(runtime) = Hecks::Ports::EventDelivery.deliveries(runtime.registry)

  it "reads a delivered reaction back as a Delivery" do
    runtime = boot.tap { |booted| place(booted) }

    expect(deliveries(runtime)).to contain_exactly(
      a_hash_including(consumer: { value: "policy:Shop::RecordOrder" }, kind: { value: "reaction" },
                       domain: { value: "Shop" }, status: "delivered", error: nil)
    )
  end

  it "names the delivery by its event and consumer" do
    runtime = boot.tap { |booted| place(booted) }
    delivery = deliveries(runtime).first

    expect(delivery[:delivery_id][:value]).to eq("#{delivery[:event_id][:value]}/policy:Shop::RecordOrder")
  end

  it "reads the deliveries a Sqlite store holds" do
    runtime = boot(adapter: "SqlitePersistence").tap { |booted| place(booted) }

    expect(deliveries(runtime).map { |delivery| delivery[:status] }).to eq(["delivered"])
  end

  it "answers a dispatch as reacted once a store has claimed its key" do
    runtime = boot
    ledger = runtime.registry.repository("Shop", runtime.registry.bluebook("Shop").aggregate("Ledger"))
    ledger.dispatch_claim("saga/k1")

    expect(Hecks::Ports::EventDelivery.reacted?(runtime.registry, key: "saga/k1")).to be(true)
  end

  it "answers a dispatch no store has claimed as not reacted" do
    expect(Hecks::Ports::EventDelivery.reacted?(boot.registry, key: "saga/none")).to be(false)
  end

  it "refuses by name when EventDelivery is not attached" do
    runtime = boot(attaches: [])

    expect { deliveries(runtime) }.to raise_error(Hecks::Runtime::WiringError, /no adapter implements the event_delivery port/)
  end

  it "refuses to choose between two adapters bound to the port" do
    adapters = %w[OutboxDelivery OtherDelivery].to_h { |name| [name, double(name: name, port: "event_delivery")] }
    registry = double(adapters: adapters)

    expect { Hecks::Ports::EventDelivery.adapter(registry) }.to raise_error(Hecks::Runtime::WiringError, /2 adapters implement/)
  end
end
