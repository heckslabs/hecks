require "spec_helper"
require "hecks/extensions/tenancy_support/ownership_scoped_repository"

RSpec.describe "Row-level authorization" do
  let(:domain) do
    Hecks.domain "OwnershipTest" do
      aggregate "Order" do
        attribute :title, String
        attribute :owner_id, String

        command "CreateOrder" do
          attribute :title, String
          attribute :owner_id, String
        end
      end
    end
  end

  let(:hecksagon_with_ownership) do
    Hecks.hecksagon do
      gate "Order", :customer do
        allow :find, :all, :count, :create
        owned_by :owner_id
      end
    end
  end

  let(:hecksagon_admin) do
    Hecks.hecksagon do
      gate "Order", :admin do
        allow :find, :all, :count, :create
      end
    end
  end

  after do
    Hecks.current_user = nil
    Hecks.tenant = nil
    Hecks.last_hecksagon = nil
  end

  describe "GateBuilder#owned_by" do
    it "stores ownership_field on the gate definition" do
      gate = hecksagon_with_ownership.gate_for("Order", :customer)
      expect(gate.ownership_field).to eq(:owner_id)
    end

    it "is nil when not declared" do
      gate = hecksagon_admin.gate_for("Order", :admin)
      expect(gate.ownership_field).to be_nil
    end
  end

  describe "OwnershipScopedRepository (unit)" do
    let(:inner) do
      obj = Object.new
      store = {}
      obj.define_singleton_method(:save) { |r| store[r.id] = r; r }
      obj.define_singleton_method(:find) { |id| store[id] }
      obj.define_singleton_method(:all) { store.values }
      obj.define_singleton_method(:delete) { |id| store.delete(id) }
      obj.define_singleton_method(:count) { store.size }
      obj.define_singleton_method(:clear) { store.clear }
      obj.define_singleton_method(:query) { |**_| store.values }
      obj
    end

    let(:record_alice) do
      r = Object.new
      r.define_singleton_method(:id) { "r1" }
      r.define_singleton_method(:owner_id) { "alice" }
      r
    end

    let(:record_bob) do
      r = Object.new
      r.define_singleton_method(:id) { "r2" }
      r.define_singleton_method(:owner_id) { "bob" }
      r
    end

    subject(:repo) do
      HecksTenancy::OwnershipScopedRepository.new(
        inner,
        ownership_field: :owner_id,
        identity_source: -> { Hecks.current_user }
      )
    end

    before do
      inner.save(record_alice)
      inner.save(record_bob)
    end

    describe "#all" do
      it "returns only the current user's records" do
        Hecks.current_user = "alice"
        expect(repo.all).to eq([record_alice])
      end

      it "returns an empty array when user has no records" do
        Hecks.current_user = "charlie"
        expect(repo.all).to be_empty
      end
    end

    describe "#find" do
      it "returns the record when the user owns it" do
        Hecks.current_user = "alice"
        expect(repo.find("r1")).to eq(record_alice)
      end

      it "raises GateAccessDenied when accessing another user's record" do
        Hecks.current_user = "bob"
        expect { repo.find("r1") }.to raise_error(Hecks::GateAccessDenied)
      end

      it "returns nil for missing records" do
        Hecks.current_user = "alice"
        expect(repo.find("missing")).to be_nil
      end
    end

    describe "#delete" do
      it "deletes owned records" do
        Hecks.current_user = "alice"
        repo.delete("r1")
        expect(inner.find("r1")).to be_nil
      end

      it "raises GateAccessDenied when deleting another user's record" do
        Hecks.current_user = "bob"
        expect { repo.delete("r1") }.to raise_error(Hecks::GateAccessDenied)
        expect(inner.find("r1")).not_to be_nil
      end
    end

    describe "#count" do
      it "counts only owned records" do
        Hecks.current_user = "alice"
        expect(repo.count).to eq(1)
      end
    end

    describe "#save" do
      it "delegates directly without ownership check" do
        Hecks.current_user = "charlie"
        new_record = Object.new
        new_record.define_singleton_method(:id) { "r3" }
        new_record.define_singleton_method(:owner_id) { "charlie" }
        repo.save(new_record)
        expect(inner.find("r3")).to eq(new_record)
      end
    end
  end

  describe "Runtime integration — customer gate with owned_by" do
    before do
      @app = Hecks.load(domain, gate: :customer, hecksagon: hecksagon_with_ownership)
    end

    it "user A cannot find user B's records" do
      Hecks.current_user = "alice"
      alice_order = OwnershipTestDomain::Order.create(title: "Alice's Order", owner_id: "alice")

      Hecks.current_user = "bob"
      expect { OwnershipTestDomain::Order.find(alice_order.id) }.to raise_error(Hecks::GateAccessDenied)
    end

    it ".all only returns the current user's records" do
      Hecks.current_user = "alice"
      OwnershipTestDomain::Order.create(title: "Alice's Order", owner_id: "alice")

      Hecks.current_user = "bob"
      OwnershipTestDomain::Order.create(title: "Bob's Order", owner_id: "bob")

      Hecks.current_user = "alice"
      expect(OwnershipTestDomain::Order.all.map(&:title)).to eq(["Alice's Order"])
    end
  end

  describe "Runtime integration — admin gate without owned_by" do
    before do
      @app = Hecks.load(domain, gate: :admin, hecksagon: hecksagon_admin)
    end

    it "has full access to all records regardless of owner" do
      Hecks.current_user = "alice"
      alice_order = OwnershipTestDomain::Order.create(title: "Alice's Order", owner_id: "alice")

      Hecks.current_user = "bob"
      expect(OwnershipTestDomain::Order.find(alice_order.id)).not_to be_nil
      expect(OwnershipTestDomain::Order.all.size).to eq(1)
    end
  end

  describe "Runtime integration — no gate (full access)" do
    before do
      @app = Hecks.load(domain)
    end

    it "allows all operations without any ownership filtering" do
      OwnershipTestDomain::Order.create(title: "Public Order", owner_id: "anyone")
      expect(OwnershipTestDomain::Order.all.size).to eq(1)
    end
  end

  describe "tenancy: :row enforcement" do
    let(:hecksagon_row_tenancy) do
      Hecks.hecksagon { tenancy :row }
    end

    let(:row_domain) do
      Hecks.domain "RowTenancyTest" do
        aggregate "Invoice" do
          attribute :amount, Integer
          attribute :tenant_id, String

          command "CreateInvoice" do
            attribute :amount, Integer
            attribute :tenant_id, String
          end
        end
      end
    end

    before do
      @app = Hecks.load(row_domain, hecksagon: hecksagon_row_tenancy)
    end

    after do
      Hecks.tenant = nil
      Hecks.last_hecksagon = nil
    end

    it "isolates records by tenant" do
      Hecks.tenant = "acme"
      RowTenancyTestDomain::Invoice.create(amount: 100, tenant_id: "acme")

      Hecks.tenant = "beta"
      expect(RowTenancyTestDomain::Invoice.all).to be_empty
    end

    it "each tenant sees only their own invoices" do
      Hecks.tenant = "acme"
      RowTenancyTestDomain::Invoice.create(amount: 100, tenant_id: "acme")

      Hecks.tenant = "beta"
      RowTenancyTestDomain::Invoice.create(amount: 200, tenant_id: "beta")

      Hecks.tenant = "acme"
      results = RowTenancyTestDomain::Invoice.all
      expect(results.size).to eq(1)
      expect(results.first.amount).to eq(100)
    end
  end
end
