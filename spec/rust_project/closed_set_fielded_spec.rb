require "spec_helper"
require_relative "../../rust/project/exemplar"
require_relative "../../rust/project/naming"
require_relative "../../rust/project/fielded"

# `fielded_capable_nested?`/`emit_closed_set_fielded_impl` — a real,
# previously-invisible gap: `fielded.rb`'s three "is this attribute a
# nested value object" sites excluded EVERY closed-set VO from a
# `Fielded` impl at all, so a `given` clause naming a closed-set-typed
# attribute (`processor: Processor`, a `one_of:` VO) could never resolve
# it — no domain in the corpus (banking/pizzas/compliance) ever declared
# a `given` over one before lifeadelics' vendored embryonaut_bluebooks/
# payments (`Payment::Succeed`'s "the processor matches..."). Found live:
# `dispatch_operation_paymentgateway_succeeded` refusing with "cannot
# resolve \"processor\" — no such attribute or argument" even though the
# aggregate held a real, rehydrated `processor` value the whole time.
#
# A MULTI-field closed set (Syntax::Keyword/Argument-shaped) stays
# excluded on purpose — no proven need, and `Field::Nested` has nothing
# to point at for a shape with no single obvious field.
RSpec.describe RustProjection::Projector do
  SINGLE_FIELD_CLOSED_SET = {
    name: "Processor", closed_set: true,
    attributes: [{ name: "value", type: "String" }],
    members: [{ "Stripe" => "stripe" }, { "PayPal" => "paypal" }]
  }.freeze

  MULTI_FIELD_CLOSED_SET = {
    name: "Keyword", closed_set: true,
    attributes: [{ name: "type", type: "String" }, { name: "resolves_via", type: "String" }],
    members: []
  }.freeze

  ORDINARY_VO = { name: "Money", closed_set: false, attributes: [{ name: "cents", type: "Integer" }] }.freeze

  describe ".fielded_capable_nested?" do
    it "admits a single-field closed set" do
      expect(described_class.fielded_capable_nested?(SINGLE_FIELD_CLOSED_SET)).to be true
    end

    it "admits any ordinary, non-closed-set VO, regardless of field count" do
      expect(described_class.fielded_capable_nested?(ORDINARY_VO)).to be true
    end

    it "refuses a multi-field closed set — no Fielded impl exists or is proven needed for that shape" do
      expect(described_class.fielded_capable_nested?(MULTI_FIELD_CLOSED_SET)).to be false
    end
  end

  describe ".emit_closed_set_fielded_impl" do
    it "answers \"value\" with the member's own raw wire text, the same single field its to_json codec already treats it as" do
      impl = described_class.emit_closed_set_fielded_impl(SINGLE_FIELD_CLOSED_SET)

      expect(impl).to include("impl crate::kernel::Fielded for Processor")
      expect(impl).to include('Processor::Stripe => "stripe".to_string()')
      expect(impl).to include('Processor::Paypal => "paypal".to_string()')
      expect(impl).to include('"value" => Some(Field::Value(Value::Str(match self {')
    end
  end

  describe "#emit_fielded_flat, given a single-field closed-set attribute" do
    it "emits a Nested arm for it — not a bare scalar, so the wire's own \"processor.value\" path keeps resolving" do
      attributes = [{ name: "processor", type: "Processor", optional: false, list: false }]
      vos = { "Processor" => SINGLE_FIELD_CLOSED_SET }

      flat = described_class.emit_fielded_flat("PaymentGatewaySucceeded", attributes, vos)

      expect(flat).to include('"processor" => Some(Field::Nested(&self.processor))')
    end
  end

  describe "#emit_fielded_flat, given a multi-field closed-set attribute" do
    it "emits no arm at all for it, same as before this fix" do
      attributes = [{ name: "kind", type: "Keyword", optional: false, list: false }]
      vos = { "Keyword" => MULTI_FIELD_CLOSED_SET }

      flat = described_class.emit_fielded_flat("SomeArgs", attributes, vos)

      expect(flat).not_to include('"kind"')
    end
  end
end
