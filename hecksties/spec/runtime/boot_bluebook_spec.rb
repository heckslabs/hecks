require "spec_helper"
require "tmpdir"
require "fileutils"

RSpec.describe "Hecks.open" do
  it "boots a bluebook with multiple chapters into runtimes" do
    book = Hecks.bluebook("OpenTest") do
      chapter "Pizzas" do
        aggregate "Pizza" do
          attribute :name, String
          command("CreatePizza") { attribute :name, String }
        end
      end

      chapter "Billing" do
        aggregate "Invoice" do
          attribute :amount, Float
          command("CreateInvoice") { attribute :amount, Float }
        end
      end
    end

    runtimes = Hecks.open(book)
    expect(runtimes).to be_an(Array)
    expect(runtimes.size).to eq(2)
    runtimes.each { |r| expect(r).to be_a(Hecks::Runtime) }
  end

  it "wires cross-chapter events through shared bus" do
    book = Hecks.bluebook("EventTest") do
      chapter "Orders" do
        aggregate "Order" do
          attribute :quantity, Integer
          command("PlaceOrder") { attribute :quantity, Integer }
        end
      end

      chapter "Shipping" do
        aggregate "Shipment" do
          attribute :quantity, Integer
          command("CreateShipment") { attribute :quantity, Integer }
        end

        policy "AutoShip" do
          on "PlacedOrder"
          trigger "CreateShipment"
          map quantity: :quantity
        end
      end
    end

    runtimes = Hecks.open(book)
    shared_bus = Hecks.shared_event_bus
    expect(shared_bus).to be_a(Hecks::EventBus)

    events = []
    shared_bus.subscribe("CreatedShipment") { |e| events << e }

    # Place an order — should trigger cross-chapter policy
    order_runtime = runtimes.find { |r| r.domain.name == "Orders" }
    order_mod = Object.const_get("OrdersDomain")
    order_mod::Order.place(quantity: 5)

    expect(events.size).to eq(1)
    expect(events.first.quantity).to eq(5)
  end
end

RSpec.describe "Hecks.boot with Bluebook file" do
  let(:tmpdir) { Dir.mktmpdir("hecks-bluebook-boot-") }

  after { FileUtils.rm_rf(tmpdir) }

  it "detects a Bluebook file and boots chapters as runtimes" do
    File.write(File.join(tmpdir, "AppBluebook"), <<~RUBY)
      Hecks.bluebook "BootDetectTest" do
        chapter "Catalog" do
          aggregate "Product" do
            attribute :name, String
            command("CreateProduct") { attribute :name, String }
          end
        end

        chapter "Sales" do
          aggregate "Sale" do
            attribute :total, Float
            command("RecordSale") { attribute :total, Float }
          end
        end
      end
    RUBY

    runtimes = Hecks.boot(tmpdir)
    expect(runtimes).to be_an(Array)
    expect(runtimes.size).to eq(2)
    expect(runtimes.map { |r| r.domain.name }).to contain_exactly("Catalog", "Sales")
  end
end
