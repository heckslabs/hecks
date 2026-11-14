require "spec_helper"

# A worktree loads its main checkout's local files, written for that checkout's code. A bind there
# to an aggregate the worktree does not declare is left out and said; the worktree's own is refused.
RSpec.describe "a bind lent by another checkout" do
  def registry_with(&)
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) do
      MemoryPorts.load!
      yield
    end
    registry
  end

  ORDER = proc do
    identified_by :id
    attribute :id, Id
    value_object("Id") { attribute :value, String }
    command "Place" do
      goal "place an order"
      attribute :id, Id
      sets :id
      emits "Placed"
    end
  end

  def declare_shop = Hecks.bluebook("Shop") { aggregate("Order", &ORDER) }

  # The Shop domain with a hecksagon that binds `Order` and `Gone`, read as lent or as its own.
  def shop(lent:)
    registry_with do
      declare_shop
      Hecks::Bluebook::Lent.during(lent) do
        Hecks.hecksagon("Shop") do
          Shop::Order.persisted_by("Memory")
          Shop::Gone.persisted_by("Memory")
        end
      end
    end
  end

  def bound(registry) = registry.hecksagon("Shop").binds.map(&:aggregate)

  it "leaves out a lent bind to an aggregate the borrower does not declare", :aggregate_failures do
    registry = shop(lent: true)
    expect { registry.verify! }.to output(/main checkout keeps Shop::Gone.*Rebase onto main/).to_stderr
    expect(bound(registry)).to eq(["Shop::Order"])
  end

  it "refuses the checkout's own bind to an aggregate it does not declare" do
    expect { shop(lent: false).verify! }.to raise_error(Hecks::Runtime::WiringError, /Shop::Gone is bound but not declared/)
  end

  it "marks nothing as lent outside a lent read" do
    expect(Hecks::Bluebook::Lent.now?).to be(false)
  end
end
