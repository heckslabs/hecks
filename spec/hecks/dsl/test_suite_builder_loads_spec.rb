# spec/hecks/dsl/test_suite_builder_loads_spec.rb
#
# Contract for Hecks::DSL::TestSuiteBuilder#loads and
# Hecks::DSL::TestBuilder#then_events_include — the i43 cross-bluebook
# behaviors DSL surface (commits 3-5 of the plan, parser-only scope).
#
# When a `.behaviors` suite declares `loads "pulse", "body"`, those
# names land on TestSuite#loads in declaration order. When a test
# inside the suite declares `then_events_include "BodyPulse", ...`,
# those names land on Test#events_include. Both fields are empty by
# default — pre-i43 `.behaviors` files build identically.
#
# Parity contract (spec/parity/behaviors_parity_test.rb) owns the
# Ruby/Rust output diff. This spec owns the Ruby-side surface: what
# the builder methods accept, how they validate, and what the IR
# contains afterwards.
#
# [antibody-exempt: spec for .behaviors DSL builder — the builder is
#  the Ruby half of the loads/then_events_include parser pair; tests
#  live alongside the builder they protect.]
#
$LOAD_PATH.unshift File.expand_path("../../../../lib", __dir__)
require "hecks/bluebook_model/structure/test_suite"
require "hecks/bluebook_model/structure/test"
require "hecks/dsl/test_suite_builder"

RSpec.describe Hecks::DSL::TestSuiteBuilder do
  describe "#loads" do
    it "records a single bluebook name" do
      builder = described_class.new("Mindstream")
      builder.loads("pulse")

      expect(builder.build.loads).to eq(["pulse"])
    end

    it "records multiple names in declaration order" do
      builder = described_class.new("Mindstream")
      builder.loads("pulse", "body", "being")

      expect(builder.build.loads).to eq(%w[pulse body being])
    end

    it "accumulates across multiple calls" do
      builder = described_class.new("Mindstream")
      builder.loads("pulse")
      builder.loads("body", "being")

      expect(builder.build.loads).to eq(%w[pulse body being])
    end

    it "leaves loads empty when not called (pre-i43 shape)" do
      builder = described_class.new("Pizzas")

      expect(builder.build.loads).to eq([])
    end

    it "coerces non-string args via to_s" do
      builder = described_class.new("Mindstream")
      builder.loads(:pulse)

      expect(builder.build.loads).to eq(["pulse"])
    end

    it "raises ArgumentError on an empty string" do
      builder = described_class.new("Mindstream")

      expect { builder.loads("pulse", "") }.to raise_error(
        ArgumentError, /bluebook name cannot be blank/
      )
    end

    it "raises ArgumentError on a whitespace-only string" do
      builder = described_class.new("Mindstream")

      expect { builder.loads("   ") }.to raise_error(
        ArgumentError, /bluebook name cannot be blank/
      )
    end
  end
end

RSpec.describe Hecks::DSL::TestBuilder do
  describe "#then_events_include" do
    def build_test(&block)
      b = Hecks::DSL::TestBuilder.new("desc")
      b.tests "SomeCmd", on: "SomeAgg"
      b.instance_eval(&block)
      b.build
    end

    it "records a single event name" do
      test = build_test { then_events_include "BodyPulse" }
      expect(test.events_include).to eq(["BodyPulse"])
    end

    it "records multiple names in declaration order" do
      test = build_test do
        then_events_include "BodyPulse", "FatigueAccumulated", "SynapsesPruned"
      end
      expect(test.events_include).to eq(
        %w[BodyPulse FatigueAccumulated SynapsesPruned],
      )
    end

    it "accumulates across multiple calls" do
      test = build_test do
        then_events_include "BodyPulse"
        then_events_include "FatigueAccumulated", "SynapsesPruned"
      end
      expect(test.events_include).to eq(
        %w[BodyPulse FatigueAccumulated SynapsesPruned],
      )
    end

    it "leaves events_include empty when not called (pre-i43 shape)" do
      test = build_test { input name: "x" }
      expect(test.events_include).to eq([])
    end

    it "coerces non-string args via to_s" do
      test = build_test { then_events_include :BodyPulse }
      expect(test.events_include).to eq(["BodyPulse"])
    end

    it "raises ArgumentError on an empty string" do
      expect {
        build_test { then_events_include "BodyPulse", "" }
      }.to raise_error(ArgumentError, /event name cannot be blank/)
    end

    it "raises ArgumentError on a whitespace-only string" do
      expect {
        build_test { then_events_include "  " }
      }.to raise_error(ArgumentError, /event name cannot be blank/)
    end
  end
end

RSpec.describe "Hecks.behaviors DSL integration for loads + then_events_include" do
  it "builds a suite with loads at the top and then_events_include inside tests" do
    builder = Hecks::DSL::TestSuiteBuilder.new("Mindstream")
    builder.vision "Cross-bluebook cascade coverage"
    builder.loads "pulse", "body"
    builder.test "Tick fans out across the body" do
      tests "Tick", on: "Mindstream"
      input at: "T0"
      then_events_include "BodyPulse", "FatigueAccumulated"
    end
    builder.test "Plain single-aggregate test (no cascade)" do
      tests "CreateNote", on: "Mindstream"
      input body: "hi"
      expect body: "hi"
    end

    suite = builder.build
    expect(suite.loads).to eq(%w[pulse body])
    expect(suite.tests.size).to eq(2)
    expect(suite.tests[0].events_include).to eq(
      %w[BodyPulse FatigueAccumulated],
    )
    expect(suite.tests[1].events_include).to eq([])
  end
end
