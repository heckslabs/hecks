# spec/hecks/validation_rules/structure/duplicate_policies_spec.rb
#
# Locks the contract for Hecks::ValidationRules::Structure::DuplicatePolicies:
# two reactive policies sharing `(event_name, trigger_command)` are flagged
# with one error that lists every colliding policy. Legitimate fan-out
# (same event, different triggers) and distinct wiring (different events,
# same trigger) pass silently.

$LOAD_PATH.unshift File.expand_path("../../../../../lib", __dir__)
require "hecks"

RSpec.describe Hecks::ValidationRules::Structure::DuplicatePolicies do
  def run_rule(domain)
    described_class.new(domain).errors
  end

  it "flags two policies sharing event and trigger" do
    domain = Hecks.bluebook("Dup") do
      aggregate "Heart" do
        attribute :beats, Integer
        command "Beat" do
          emits "HeartBeat"
        end
        command "Tick" do
          reference_to(Heart)
          emits "Ticked"
        end
      end
      policy "TickOnBeat"      do; on "HeartBeat"; trigger "Tick"; end
      policy "TickOnBeatAgain" do; on "HeartBeat"; trigger "Tick"; end
    end

    errors = run_rule(domain)
    expect(errors.size).to eq(1)

    msg = errors.first.message
    expect(msg).to include("HeartBeat")
    expect(msg).to include("Tick")
    expect(msg).to include("TickOnBeat")
    expect(msg).to include("TickOnBeatAgain")
  end

  it "passes when policies share an event but differ by trigger" do
    domain = Hecks.bluebook("FanOut") do
      aggregate "Order" do
        attribute :status, String
        command "PlaceOrder" do
          emits "OrderPlaced"
        end
        command "NotifyKitchen" do
          reference_to(Order)
          emits "KitchenNotified"
        end
        command "ChargeCard" do
          reference_to(Order)
          emits "CardCharged"
        end
      end
      policy "KitchenOnPlaced" do; on "OrderPlaced"; trigger "NotifyKitchen"; end
      policy "ChargeOnPlaced"  do; on "OrderPlaced"; trigger "ChargeCard";    end
    end

    expect(run_rule(domain)).to be_empty
  end

  it "passes when policies share a trigger but listen on different events" do
    domain = Hecks.bluebook("CrossEvent") do
      aggregate "Bell" do
        attribute :name, String
        command "Ring" do
          emits "Rang"
        end
        command "Chime" do
          emits "Chimed"
        end
        command "Echo" do
          reference_to(Bell)
          emits "Echoed"
        end
      end
      policy "EchoOnRang"   do; on "Rang";   trigger "Echo"; end
      policy "EchoOnChimed" do; on "Chimed"; trigger "Echo"; end
    end

    expect(run_rule(domain)).to be_empty
  end

  it "names all three policies in a three-way duplicate and reflects the count" do
    domain = Hecks.bluebook("Triple") do
      aggregate "Bell" do
        attribute :name, String
        command "Ring" do
          emits "Rang"
        end
        command "Echo" do
          reference_to(Bell)
          emits "Echoed"
        end
      end
      policy "EchoA" do; on "Rang"; trigger "Echo"; end
      policy "EchoB" do; on "Rang"; trigger "Echo"; end
      policy "EchoC" do; on "Rang"; trigger "Echo"; end
    end

    errors = run_rule(domain)
    expect(errors.size).to eq(1)
    msg = errors.first.message
    expect(msg).to include("3 policies")
    %w[EchoA EchoB EchoC].each { |name| expect(msg).to include(name) }
  end

  it "does not flag cross-aggregate dispatch (A triggers command on B that emits to A)" do
    # Different (event, trigger) pairs: no dupe, even though the chain
    # loops back. That's cycle detection's job, not duplicate detection.
    domain = Hecks.bluebook("Cycle") do
      aggregate "A" do
        attribute :id, String
        command "Kick" do
          emits "AKicked"
        end
        command "Reply" do
          reference_to(A)
          emits "AReplied"
        end
      end
      aggregate "B" do
        attribute :id, String
        command "Handle" do
          emits "BHandled"
        end
      end
      policy "HandleOnKick"  do; on "AKicked";   trigger "Handle"; end
      policy "ReplyOnHandle" do; on "BHandled";  trigger "Reply";  end
    end

    expect(run_rule(domain)).to be_empty
  end
end
