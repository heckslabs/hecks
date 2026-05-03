# spec/hecks/dsl/process_manager_builder_spec.rb
#
# Contract for Hecks::DSL::ProcessManagerBuilder — Phase 1 of the
# dream-study plan. The builder turns a `process_manager "Name" do ... end`
# bluebook block into a BluebookModel::Behavior::ProcessManager IR node,
# mirroring the runtime class +Hecks::EventSourcing::ProcessManager+.
#
# This spec owns the Ruby-side parser surface :
#
# - what each keyword (correlates_by, starts_on, ends_on, state, on) records
# - what the action block does NOT do (it's captured, not executed)
# - validation rules raised at build-time:
#     1. every state in any transition must be declared via `state`
#     2. correlates_by must be a Symbol
#     3. starts_on / ends_on must be Strings (event type names)
#     4. at least one state must be declared
#     5. at least one `on` handler must be declared
#
# Phase 2 (runtime wiring) and Phase 3 (Rust parser) ship the executable
# end and the parity proof respectively. This file covers only what the
# Ruby builder hands the IR layer.
#
# [antibody-exempt: spec for new DSL builder — the builder is the Ruby
#  half of the process_manager parser pair; tests live alongside the
#  builder they protect.]
#
$LOAD_PATH.unshift File.expand_path("../../../../ruby", __dir__)
require "hecks/bluebook_model/behavior/process_manager"
require "hecks/dsl/describable"
require "hecks/dsl/process_manager_builder"

RSpec.describe Hecks::DSL::ProcessManagerBuilder do
  def build_minimal
    builder = described_class.new("SleepCycle")
    builder.correlates_by :body_id
    builder.starts_on    "SleepStarted"
    builder.ends_on      "WakeFinished"
    builder.state "light"
    builder.state "rem"
    builder.state "deep"
    builder.state "studying_dream"
    builder.on "PhaseElapsed", transition: { light: :light } do |_event, _pm|
      { commands: ["AdvancePhase"] }
    end
    builder.on "DreamPulsed", transition: { rem: :rem } do |_event, _pm|
      { commands: ["RecordDream"] }
    end
    builder
  end

  describe "#build — happy path" do
    let(:pm) { build_minimal.build }

    it "returns a Behavior::ProcessManager IR node" do
      expect(pm).to be_a(Hecks::BluebookModel::Behavior::ProcessManager)
    end

    it "captures the PM name as a String" do
      expect(pm.name).to eq("SleepCycle")
    end

    it "captures correlates_by as a Symbol" do
      expect(pm.correlates_by).to eq(:body_id)
    end

    it "captures starts_on / ends_on as Strings" do
      expect(pm.starts_on).to eq("SleepStarted")
      expect(pm.ends_on).to   eq("WakeFinished")
    end

    it "captures declared states in declaration order" do
      expect(pm.states).to eq(%w[light rem deep studying_dream])
    end

    it "captures one Handler per `on` declaration in declaration order" do
      expect(pm.handlers.size).to eq(2)
      expect(pm.handlers.map(&:event_type)).to eq(%w[PhaseElapsed DreamPulsed])
    end

    it "records each handler's transition map exactly as declared" do
      phase = pm.handler_for("PhaseElapsed")
      dream = pm.handler_for("DreamPulsed")
      expect(phase.transition).to eq(light: :light)
      expect(dream.transition).to eq(rem: :rem)
    end

    it "captures the action block as a Proc (not invoked at build time)" do
      phase = pm.handler_for("PhaseElapsed")
      expect(phase.action).to be_a(Proc)
      # Mirrors runtime API: action.call(event, pm_instance) → { commands: [...] }
      expect(phase.action.call(:fake_event, :fake_instance))
        .to eq(commands: ["AdvancePhase"])
    end

    it "lets `on` be declared without a block (action is nil)" do
      builder = described_class.new("Tiny")
      builder.correlates_by :id
      builder.starts_on "Started"
      builder.state "a"
      builder.on "Pinged", transition: { a: :a }

      pm = builder.build
      expect(pm.handlers.first.action).to be_nil
    end

    it "treats ends_on as optional" do
      builder = described_class.new("Tiny")
      builder.correlates_by :id
      builder.starts_on "Started"
      builder.state "a"
      builder.on "Pinged", transition: { a: :a }

      expect(builder.build.ends_on).to be_nil
    end
  end

  describe "block-style DSL via instance_eval" do
    it "parses the locked Phase 1 surface end-to-end" do
      builder = described_class.new("SleepCycle")
      builder.instance_eval do
        correlates_by :body_id
        starts_on    "SleepStarted"
        ends_on      "WakeFinished"
        state "light"
        state "rem"
        state "deep"
        state "studying_dream"

        on "PhaseElapsed", transition: { light: :light } do |_event, _pm|
          { commands: ["AdvancePhase"] }
        end
        on "DreamPulsed", transition: { rem: :rem } do |_event, _pm|
          { commands: ["RecordDream"] }
        end
      end

      pm = builder.build
      expect(pm.states).to       include("studying_dream")
      expect(pm.handlers.size).to eq(2)
    end
  end

  describe "validation — raises ArgumentError at #build" do
    it "rejects a transition referencing an undeclared state" do
      builder = described_class.new("Bad")
      builder.correlates_by :id
      builder.starts_on "Started"
      builder.state "a"
      builder.on "Pinged", transition: { a: :b } # :b undeclared

      expect { builder.build }
        .to raise_error(ArgumentError, /undeclared state/)
    end

    it "rejects a transition whose `from` is undeclared" do
      builder = described_class.new("Bad")
      builder.correlates_by :id
      builder.starts_on "Started"
      builder.state "a"
      builder.on "Pinged", transition: { x: :a }

      expect { builder.build }
        .to raise_error(ArgumentError, /undeclared state.*x/)
    end

    it "rejects correlates_by that isn't a Symbol" do
      builder = described_class.new("Bad")
      builder.correlates_by "body_id"
      builder.starts_on "Started"
      builder.state "a"
      builder.on "Pinged", transition: { a: :a }

      expect { builder.build }
        .to raise_error(ArgumentError, /correlates_by must be a Symbol/)
    end

    it "rejects starts_on that isn't a String" do
      builder = described_class.new("Bad")
      builder.correlates_by :id
      builder.starts_on :Started
      builder.state "a"
      builder.on "Pinged", transition: { a: :a }

      expect { builder.build }
        .to raise_error(ArgumentError, /starts_on must be a String/)
    end

    it "rejects ends_on that isn't a String when present" do
      builder = described_class.new("Bad")
      builder.correlates_by :id
      builder.starts_on "Started"
      builder.ends_on :Finished
      builder.state "a"
      builder.on "Pinged", transition: { a: :a }

      expect { builder.build }
        .to raise_error(ArgumentError, /ends_on must be a String/)
    end

    it "rejects a missing starts_on" do
      builder = described_class.new("Bad")
      builder.correlates_by :id
      builder.state "a"
      builder.on "Pinged", transition: { a: :a }

      expect { builder.build }
        .to raise_error(ArgumentError, /missing required starts_on/)
    end

    it "rejects when no states are declared" do
      builder = described_class.new("Bad")
      builder.correlates_by :id
      builder.starts_on "Started"

      expect { builder.build }
        .to raise_error(ArgumentError, /at least one state/)
    end

    it "rejects when no handlers are declared" do
      builder = described_class.new("Bad")
      builder.correlates_by :id
      builder.starts_on "Started"
      builder.state "a"

      expect { builder.build }
        .to raise_error(ArgumentError, /at least one on-handler/)
    end

    it "rejects an on-block with a multi-entry transition hash" do
      builder = described_class.new("Bad")
      builder.correlates_by :id
      builder.starts_on "Started"
      builder.state "a"
      builder.state "b"

      expect {
        builder.on "Pinged", transition: { a: :a, b: :b }
      }.to raise_error(ArgumentError, /single-entry/)
    end
  end

  describe "declarative dispatch form" do
    def builder
      b = described_class.new("OrderFulfillment")
      b.correlates_by :order_id
      b.starts_on "OrderPlaced"
      b.state "started"
      b.state "shipped"
      b
    end

    it "captures dispatch lines from a no-arg block" do
      b = builder
      b.on("OrderShipped", transition: { started: :shipped }) do
        dispatch "Inventory.Decrement"
        dispatch "Notification.Send"
      end

      pm = b.build
      handler = pm.handlers.first
      # Phase 2.b — dispatches are structured DispatchSpec objects.
      # Bare-string form lifts to a spec with empty with_spec.
      expect(handler.dispatches.map(&:command_name))
        .to eq(["Inventory.Decrement", "Notification.Send"])
      expect(handler.dispatches.map(&:with_spec)).to eq([[], []])
      expect(handler.action).to be_nil
    end

    it "captures with: literal entries" do
      b = builder
      b.on("OrderShipped", transition: { started: :shipped }) do
        dispatch "Inventory.Decrement", with: { name: "body", count: 1 }
      end
      pm = b.build
      spec = pm.handlers.first.dispatches.first
      expect(spec.command_name).to eq("Inventory.Decrement")
      expect(spec.with_spec.map(&:first)).to eq(%w[name count])
      expect(spec.with_spec.map { |_, s| s.kind }).to eq(%i[literal literal])
      expect(spec.with_spec.map { |_, s| s.value }).to eq(["body", 1])
    end

    it "captures from_event sentinels with optional default" do
      b = builder
      b.on("OrderShipped", transition: { started: :shipped }) do
        dispatch "Inventory.Decrement", with: {
          tick: from_event(:tick),
          when: from_event(:occurred_at, default: "now")
        }
      end
      pm = b.build
      spec = pm.handlers.first.dispatches.first
      tick = spec.with_spec.assoc("tick").last
      whenv = spec.with_spec.assoc("when").last
      expect(tick.kind).to eq(:from_event)
      expect(tick.name).to eq(:tick)
      expect(tick.default).to be_nil
      expect(whenv.kind).to eq(:from_event)
      expect(whenv.default).to eq("now")
    end

    it "captures from_pm sentinels with default fallback" do
      b = builder
      b.on("OrderShipped", transition: { started: :shipped }) do
        dispatch "Inventory.Decrement", with: {
          carrying: from_pm(:carrying, default: "—")
        }
      end
      pm = b.build
      spec = pm.handlers.first.dispatches.first
      carrying = spec.with_spec.assoc("carrying").last
      expect(carrying.kind).to eq(:from_pm)
      expect(carrying.name).to eq(:carrying)
      expect(carrying.default).to eq("—")
    end

    it "preserves with: declaration order" do
      b = builder
      b.on("OrderShipped", transition: { started: :shipped }) do
        dispatch "X.Y", with: { a: 1, b: 2, c: 3, d: 4 }
      end
      pm = b.build
      spec = pm.handlers.first.dispatches.first
      expect(spec.with_spec.map(&:first)).to eq(%w[a b c d])
    end

    it "preserves the action proc when block has |event, pm| arity" do
      b = builder
      b.on("OrderShipped", transition: { started: :shipped }) do |event, pm|
        { commands: ["Inventory.Decrement"] }
      end

      pm = b.build
      handler = pm.handlers.first
      expect(handler.action).to be_a(Proc)
      expect(handler.dispatches).to eq([])
    end

    it "defaults dispatches to [] when no block" do
      b = builder
      b.on("OrderShipped", transition: { started: :shipped })
      pm = b.build
      handler = pm.handlers.first
      expect(handler.dispatches).to eq([])
      expect(handler.action).to be_nil
    end
  end
end
