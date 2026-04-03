require "spec_helper"

RSpec.describe "Saga / Process Manager (HEC-421)", :slow do
  let(:domain) do
    Hecks.domain "SagaTest" do
      aggregate "Order" do
        attribute :item, String
        attribute :status, String

        command "ReserveInventory" do
          attribute :item, String
        end

        command "ChargePayment" do
          attribute :item, String
        end

        command "ReleaseInventory" do
          attribute :item, String
        end

        command "RefundPayment" do
          attribute :item, String
        end

        command "CancelOrder" do
          attribute :item, String
        end
      end

      saga "OrderFulfillment" do
        step "ReserveInventory" do
          on_success "InventoryReserved"
          on_failure "ReservationFailed"
          compensate "ReleaseInventory"
        end
        step "ChargePayment" do
          on_success "PaymentCharged"
          on_failure "PaymentFailed"
          compensate "RefundPayment"
        end
        timeout "48h"
        on_timeout "CancelOrder"
      end
    end
  end

  before { @app = Hecks.load(domain) }

  describe "IR classes" do
    it "registers sagas in the domain IR" do
      expect(domain.sagas.size).to eq(1)
      saga = domain.sagas.first
      expect(saga).to be_a(Hecks::DomainModel::Behavior::Saga)
      expect(saga.name).to eq("OrderFulfillment")
      expect(saga.steps.size).to eq(2)
      expect(saga.timeout).to eq("48h")
      expect(saga.on_timeout).to eq("CancelOrder")
      expect(saga.timed?).to be true
    end

    it "builds saga steps with all attributes" do
      step = domain.sagas.first.steps.first
      expect(step).to be_a(Hecks::DomainModel::Behavior::SagaStep)
      expect(step.command).to eq("ReserveInventory")
      expect(step.on_success).to eq("InventoryReserved")
      expect(step.on_failure).to eq("ReservationFailed")
      expect(step.compensate).to eq("ReleaseInventory")
      expect(step.compensatable?).to be true
    end
  end

  describe "runtime wiring" do
    it "exposes start_<saga_name> method on the domain module" do
      expect(SagaTestDomain).to respond_to(:start_order_fulfillment)
    end

    it "executes saga happy path to completion" do
      result = SagaTestDomain.start_order_fulfillment(item: "Widget")
      expect(result[:state]).to eq(:completed)
      expect(result[:completed_steps]).to eq([0, 1])
      expect(result[:error]).to be_nil
      expect(result[:saga_id]).to start_with("saga_")
    end
  end

  describe "compensation on failure" do
    it "compensates completed steps when a step fails" do
      compensated = []
      # Intercept command dispatch to fail on ChargePayment
      @app.use(:saga_fail_test) do |cmd, next_mw|
        if cmd.class.name.include?("ChargePayment")
          raise "Payment gateway unavailable"
        elsif cmd.class.name.include?("ReleaseInventory")
          compensated << "ReleaseInventory"
        end
        next_mw.call
      end

      result = SagaTestDomain.start_order_fulfillment(item: "Widget")
      expect(result[:state]).to eq(:failed)
      expect(result[:error]).to include("ChargePayment")
      expect(compensated).to eq(["ReleaseInventory"])
    end
  end

  describe "legacy keyword step syntax" do
    let(:legacy_domain) do
      Hecks.domain "LegacySagaTest" do
        aggregate "Task" do
          attribute :name, String
          command "StepOne" do
            attribute :name, String
          end
          command "StepTwo" do
            attribute :name, String
          end
        end

        saga "SimpleProcess" do
          step "StepOne", on_success: "StepOneDone"
          step "StepTwo", on_success: "StepTwoDone"
        end
      end
    end

    before { @legacy_app = Hecks.load(legacy_domain) }

    it "supports keyword-based step definitions" do
      saga = legacy_domain.sagas.first
      expect(saga.steps.size).to eq(2)
      expect(saga.steps.first.command).to eq("StepOne")
      expect(saga.steps.first.on_success).to eq("StepOneDone")
    end

    it "runs the saga to completion" do
      result = LegacySagaTestDomain.start_simple_process(name: "test")
      expect(result[:state]).to eq(:completed)
    end
  end

  describe "timeout metadata" do
    it "records timeout on the saga IR" do
      saga = domain.sagas.first
      expect(saga.timed?).to be true
      expect(saga.timeout).to eq("48h")
      expect(saga.on_timeout).to eq("CancelOrder")
    end

    it "marks sagas without timeout as not timed" do
      no_timeout = Hecks::DomainModel::Behavior::Saga.new(name: "Quick")
      expect(no_timeout.timed?).to be false
    end
  end

  describe "saga store" do
    it "persists and retrieves saga instances" do
      store = Hecks::SagaStore.new
      store.save("id-1", { state: :running })
      expect(store.find("id-1")).to eq({ state: :running })
      store.delete("id-1")
      expect(store.find("id-1")).to be_nil
    end
  end
end
