require "spec_helper"
require_relative "../support/read_model_spec_helpers"

# ADR 0126: `group_by` with one reduction nests the rows by the grouped fields and answers each
# leaf with the reduction of that leaf's rows, in place of the row.
RSpec.describe "a read model that groups and reduces" do
  include ReadModelSpecHelpers

  # Two-level grouping over a small domain, so every reducer can be read off one shelf of rows.
  SHELF_DOMAIN = proc do
    vision "Stock on shelves, reported by aisle and bay."
    generic

    aggregate "Item" do
      identified_by :sku
      attribute :sku, Sku
      attribute :aisle, Aisle
      attribute :bay, Bay
      attribute :units, Units
      attribute :fragile, Fragile

      { "Sku" => String, "Aisle" => String, "Bay" => String, "Units" => Integer, "Fragile" => TrueClass }
        .each { |name, type| value_object(name) { attribute :value, type } }

      command "Shelve" do
        attribute :sku, Sku
        attribute :aisle, Aisle
        attribute :bay, Bay
        attribute :units, Units
        attribute :fragile, Fragile
        %i[sku aisle bay units fragile].each { |field| sets field }
        emits "ItemShelved"
      end
    end

    { "UnitsByAisle" => [:sum, :units], "MeanByAisle" => [:avg, :units], "FewestByAisle" => [:min, :units],
      "AnyFragileByAisle" => [:any, :fragile], "MedianByAisle" => [:median, :units] }.each do |name, (word, field)|
      read_model(name) do
        include Item

        group_by :aisle
        public_send(word, field)
      end
    end

    read_model "UnitsByAisleAndBay" do
      include Item

      group_by :aisle, :bay
      sum :units
    end
  end

  TWO_REDUCTIONS_DOMAIN = proc do
    instance_exec(&SHELF_DOMAIN)

    read_model "Both" do
      include Item

      group_by :aisle
      sum :units
      count
    end
  end

  SHELVED = [%w[i1 a 1 4], %w[i2 a 1 6], %w[i3 a 2 5], %w[i4 b 1 7]].freeze

  def shelf_runtime(rows = SHELVED)
    runtime = boot_memory_domain("Shelf", SHELF_DOMAIN, aggregates: %w[Item])
    rows.each do |sku, aisle, bay, units|
      Shelf::Item.shelve!(sku: sku, aisle: aisle, bay: bay, units: units.to_i, fragile: sku == "i4")
    end
    runtime
  end

  def answer(runtime, name) = runtime.query("Shelf.#{name}").first[:items]

  it "adds up each group" do
    expect(answer(shelf_runtime, "units_by_aisle")).to eq("a" => 15, "b" => 7)
  end

  it "nests one level a field and reduces the leaves" do
    expect(answer(shelf_runtime, "units_by_aisle_and_bay")).to eq("a" => { "1" => 10, "2" => 5 }, "b" => { "1" => 7 })
  end

  it "averages, takes the least and the median of each group", :aggregate_failures do
    runtime = shelf_runtime
    expect(answer(runtime, "mean_by_aisle")).to eq("a" => 5.0, "b" => 7.0)
    expect(answer(runtime, "fewest_by_aisle")).to eq("a" => 4, "b" => 7)
    expect(answer(runtime, "median_by_aisle")).to eq("a" => 5, "b" => 7)
  end

  it "answers a boolean reducer for each group" do
    expect(answer(shelf_runtime, "any_fragile_by_aisle")).to eq("a" => false, "b" => true)
  end

  it "answers no groups when there are no rows" do
    expect(answer(shelf_runtime([]), "units_by_aisle")).to eq({})
  end

  it "still refuses two reductions declared together" do
    expect(&domain_build("ShelfBoth", TWO_REDUCTIONS_DOMAIN)).to raise_error(Hecks::Bluebook::DSL::Malformed, /declares both/)
  end

  context "with the banking example" do
    def authorize(account, index, cents)
      Banking::CardPayment.authorize!(account: account, authorisation: { value: "auth-g-#{index}" },
                                      amount: { cents: cents }, merchant: { value: "Shop#{index}" })
    end

    def open_account
      Banking::Customer.register!(reference: { value: "c-grouped" }, name: { given: "A", family: "B" },
                                  email: { address: "grouped@example.com" })
      Banking::Account.open!(customer: "c-grouped", number: { value: "acct-grouped" },
                             kind: { name: "current" }, daily_limit: { cents: 10_000 })
    end

    def banking_runtime
      runtime = boot_banking_bundle
      open_account
      payments = [100, 250, 400].each_with_index.map { |cents, index| authorize("acct-grouped", index, cents) }
      payments.last.capture!
      runtime
    end

    it "totals the card charges of each status" do
      rows = banking_runtime.query("Banking.card_payment_totals_by_status").first[:card_payments]
      expect(rows).to eq("authorized" => 350, "captured" => 400)
    end

    it "counts the card charges of each status" do
      rows = banking_runtime.query("Banking.card_payment_counts_by_status").first[:card_payments]
      expect(rows).to eq("authorized" => 2, "captured" => 1)
    end
  end
end
