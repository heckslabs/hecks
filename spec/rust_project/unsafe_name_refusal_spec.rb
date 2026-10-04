require "spec_helper"
require_relative "../../rust/project/naming"

# A declared name is written into the generated crate as a field, struct or function name, so one
# that is not a plain identifier would inject code into it. The Rust twin is
# `naming::unsafe_name_refusal` (rust/codegen/src/naming.rs); both must say the same thing.
RSpec.describe RustProjection::Projector, ".unsafe_name_refusal" do
  def ir_with_attribute(name)
    { name: "Shop", aggregates: [{ name: "Pizza", attributes: [{ name: "size" }, { name: name }] }] }
  end

  it "refuses an attribute name that would inject a field into the generated struct" do
    refusal = described_class.unsafe_name_refusal("shop", ir_with_attribute("a: String, pub evil: u8"))

    expect(refusal).to start_with('shop: declared name(s) "a: String, pub evil: u8" can\'t be used as-is')
  end

  it "names every offender once" do
    ir = { aggregates: [{ name: "Pizza", commands: [{ name: "Add-Topping" }, { name: "Add-Topping" }, { name: "x y" }] }] }

    expect(described_class.unsafe_name_refusal("shop", ir)).to include('"Add-Topping", "x y"')
  end

  it "accepts plain identifiers and ignores the field maps under mutations" do
    command = { name: "AddTopping", mutations: [{ fields: { name: ":topping" } }] }
    ir = { name: "Shop", aggregates: [{ name: "Pizza", commands: [command] }] }

    expect(described_class.unsafe_name_refusal("shop", ir)).to be_nil
  end

  it "ignores the data paths an era edge names (a backfill into a nested value object)" do
    edge = { aggregates: [{ name: "Registration", backfills: [{ name: "attendee.first_name" }] }] }
    ir = { name: "Shop", aggregates: [{ name: "Pizza" }], translations: [edge] }

    expect(described_class.unsafe_name_refusal("shop", ir)).to be_nil
  end

  it "refuses a name that starts with a digit" do
    expect(described_class.unsafe_name_refusal("shop", ir_with_attribute("1st"))).to include('"1st"')
  end
end
