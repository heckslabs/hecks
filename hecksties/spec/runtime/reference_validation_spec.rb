require "spec_helper"

RSpec.describe "Reference ID boundary validation (IDOR prevention)" do
  let(:domain) do
    Hecks.domain "Pizzas" do
      aggregate "Pizza" do
        attribute :name, String

        command "CreatePizza" do
          attribute :name, String
        end
      end

      aggregate "Order" do
        reference_to "Pizza"
        attribute :quantity, Integer

        command "PlaceOrder" do
          reference_to "Pizza"
          attribute :quantity, Integer
        end

        command "DispatchOrder" do
          reference_to "Pizza", validate: false
          attribute :quantity, Integer
        end

        command "VerifyStock" do
          reference_to "Pizza", validate: :exists
          attribute :quantity, Integer
        end
      end
    end
  end

  let!(:app) { Hecks.load(domain) }

  after { Hecks::Utils.cleanup_constants! }

  describe "valid reference ID" do
    it "allows the command when the referenced aggregate exists" do
      PizzasDomain::Pizza.create(name: "Margherita")
      pizza = PizzasDomain::Pizza.all.first
      result = PizzasDomain::Order.place(pizza: pizza.id, quantity: 2)
      expect(result.aggregate).to be_a(PizzasDomain::Order)
    end
  end

  describe "nonexistent reference ID" do
    it "raises ReferenceNotFound for an unknown ID" do
      expect {
        PizzasDomain::Order.place(pizza: "does-not-exist", quantity: 1)
      }.to raise_error(Hecks::ReferenceNotFound)
    end

    it "includes reference_type and reference_id in the error" do
      begin
        PizzasDomain::Order.place(pizza: "ghost-id", quantity: 1)
      rescue Hecks::ReferenceNotFound => e
        expect(e.reference_type).to eq("Pizza")
        expect(e.reference_id).to eq("ghost-id")
        expect(e.message).to include("Pizza")
        expect(e.message).to include("ghost-id")
      end
    end
  end

  describe "nil reference value" do
    it "passes when the reference field is nil (nullable)" do
      expect {
        PizzasDomain::Order.place(pizza: nil, quantity: 1)
      }.not_to raise_error
    end
  end

  describe "validate: false — opt-out for eventual consistency" do
    it "skips validation entirely and does not raise" do
      expect {
        PizzasDomain::Order.dispatch(pizza: "nonexistent-id", quantity: 1)
      }.not_to raise_error
    end
  end

  describe "validate: :exists — existence check only" do
    it "raises ReferenceNotFound when the record does not exist" do
      expect {
        PizzasDomain::Order.verify_stock(pizza: "missing-id", quantity: 1)
      }.to raise_error(Hecks::ReferenceNotFound)
    end

    it "passes when the record exists, even without an authorizer" do
      PizzasDomain::Pizza.create(name: "Napoli")
      pizza = PizzasDomain::Pizza.all.first
      expect {
        PizzasDomain::Order.verify_stock(pizza: pizza.id, quantity: 1)
      }.not_to raise_error
    end
  end

  describe "reference_authorizer hook" do
    let(:rejecting_authorizer) { ->(_ref, _record, _cmd) { false } }
    let(:accepting_authorizer) { ->(_ref, _record, _cmd) { true } }

    before do
      PizzasDomain::Pizza.create(name: "Secure")
      @pizza_id = PizzasDomain::Pizza.all.first.id
    end

    it "raises ReferenceAccessDenied when the authorizer returns false" do
      cmd_class = PizzasDomain::Order::Commands::PlaceOrder
      cmd_class.reference_authorizer = rejecting_authorizer

      expect {
        PizzasDomain::Order.place(pizza: @pizza_id, quantity: 1)
      }.to raise_error(Hecks::ReferenceAccessDenied)

      cmd_class.reference_authorizer = nil
    end

    it "passes when the authorizer returns true" do
      cmd_class = PizzasDomain::Order::Commands::PlaceOrder
      cmd_class.reference_authorizer = accepting_authorizer

      expect {
        PizzasDomain::Order.place(pizza: @pizza_id, quantity: 1)
      }.not_to raise_error

      cmd_class.reference_authorizer = nil
    end

    it "includes reference_type, reference_id in the access denied error" do
      cmd_class = PizzasDomain::Order::Commands::PlaceOrder
      cmd_class.reference_authorizer = rejecting_authorizer

      begin
        PizzasDomain::Order.place(pizza: @pizza_id, quantity: 1)
      rescue Hecks::ReferenceAccessDenied => e
        expect(e.reference_type).to eq("Pizza")
        expect(e.reference_id).to eq(@pizza_id)
      end

      cmd_class.reference_authorizer = nil
    end

    it "skips authorizer for validate: :exists references" do
      cmd_class = PizzasDomain::Order::Commands::VerifyStock
      cmd_class.reference_authorizer = rejecting_authorizer

      expect {
        PizzasDomain::Order.verify_stock(pizza: @pizza_id, quantity: 1)
      }.not_to raise_error

      cmd_class.reference_authorizer = nil
    end
  end

  describe "dry_call also validates references" do
    it "raises ReferenceNotFound in dry_call when ID does not exist" do
      cmd_class = PizzasDomain::Order::Commands::PlaceOrder
      expect {
        cmd_class.dry_call(pizza: "fake-id", quantity: 1)
      }.to raise_error(Hecks::ReferenceNotFound)
    end

    it "passes dry_call when the referenced record exists" do
      PizzasDomain::Pizza.create(name: "Dry Pizza")
      pizza = PizzasDomain::Pizza.all.first
      expect {
        cmd_class = PizzasDomain::Order::Commands::PlaceOrder
        cmd_class.dry_call(pizza: pizza.id, quantity: 1)
      }.not_to raise_error
    end
  end

  describe "ReferenceNotFound error serialization" do
    it "serializes to structured JSON" do
      err = Hecks::ReferenceNotFound.new(
        "Pizza 'x' not found",
        reference_type: "Pizza",
        reference_id: "x"
      )
      json = err.as_json
      expect(json[:error]).to eq("ReferenceNotFound")
      expect(json[:message]).to include("Pizza")
      expect(json[:reference_type]).to eq("Pizza")
      expect(json[:reference_id]).to eq("x")
    end
  end

  describe "ReferenceAccessDenied error serialization" do
    it "serializes to structured JSON" do
      err = Hecks::ReferenceAccessDenied.new(
        "Access denied to Pizza 'x'",
        reference_type: "Pizza",
        reference_id: "x",
        actor: "user-42"
      )
      json = err.as_json
      expect(json[:error]).to eq("ReferenceAccessDenied")
      expect(json[:message]).to include("Pizza")
      expect(json[:reference_type]).to eq("Pizza")
      expect(json[:reference_id]).to eq("x")
      expect(json[:actor]).to eq("user-42")
    end
  end
end
