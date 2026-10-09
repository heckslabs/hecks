require "spec_helper"

# ADR 0096: `mark :holds_seat, "pending", "succeeded"` names a meaning and the lifecycle states
# that carry it. The IR gains `marks` only when a lifecycle declares one.
RSpec.describe "lifecycle marks" do
  def build(&block)
    Hecks::Bluebook::DSL::LifecycleBuilder.build(:status, default: "pending", &block)
  end

  def refuses(pattern) = raise_error(Hecks::Bluebook::DSL::Malformed, pattern)

  let(:payment) do
    build do
      mark :holds_seat, "pending", "succeeded"
      transition "Succeed" => "succeeded", from: "pending"
      transition "Decline" => "declined",  from: "pending"
    end
  end

  let(:fixture_chapter) do
    source = File.read(File.expand_path("fixtures/lifecycle_marks.bluebook", __dir__))
    Hecks.with_registry(Hecks::Runtime::Registry.new) { eval(source, TOPLEVEL_BINDING) }
  end

  it "reads the states a mark names, in declared order" do
    expect(payment.marked(:holds_seat)).to eq(%w[pending succeeded])
  end

  it "answers nil for a mark it does not carry" do
    expect(payment.marked(:unknown)).to be_nil
  end

  it "emits marks as a name => states map" do
    expect(payment.to_h[:marks]).to eq("holds_seat" => %w[pending succeeded])
  end

  it "leaves marks out of the IR when the lifecycle declares none" do
    plain = build { transition "Succeed" => "succeeded", from: "pending" }

    expect(plain.to_h.keys).to eq(%i[field default transitions])
  end

  it "accepts a mark that names the default state alone" do
    expect(build { mark :new_thing, "pending" }.marked(:new_thing)).to eq(["pending"])
  end

  it "refuses a state the lifecycle does not have" do
    expect { build { mark :holds_seat, "pending", "nope" } }.to refuses(/mark :holds_seat names "nope"/)
  end

  it "refuses a state that is only a from: guard" do
    guard_only = proc do
      mark :holds_seat, "ghost"
      transition "Succeed" => "succeeded", from: "ghost"
    end

    expect { build(&guard_only) }.to refuses(/"ghost"/)
  end

  it "refuses a name that is not a lowercase word" do
    expect { build { mark :HoldsSeat, "pending" } }.to refuses(/not a lowercase word/)
  end

  it "refuses a state named twice in one mark" do
    expect { build { mark :holds_seat, "pending", "pending" } }.to refuses(/names state "pending" twice/)
  end

  it "refuses a mark declared twice" do
    twice = proc do
      mark :holds_seat, "pending"
      mark :holds_seat, "pending"
    end

    expect { build(&twice) }.to refuses(/declares mark :holds_seat twice/)
  end

  it "refuses a mark with no states" do
    expect { build { mark :holds_seat } }.to refuses(/names no states/)
  end

  it "carries marks through a whole bluebook on an aggregate" do
    paying = fixture_chapter.aggregates.find { |aggregate| aggregate.name == "Payment" }

    expect(paying.lifecycle.marked(:holds_seat)).to eq(%w[pending succeeded disputed])
  end

  it "carries marks through a whole bluebook on a nested entity" do
    order = fixture_chapter.aggregates.find { |aggregate| aggregate.name == "Order" }

    expect(order.entities.first.lifecycle.marked(:settled)).to eq(%w[shipped delivered])
  end
end
