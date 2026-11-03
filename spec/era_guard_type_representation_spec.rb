require "hecks"
require "hecks/ports/persistence/plugins/era"

# A stored shape holds every attribute type as its string; a declared bluebook may hold an object
# that prints as the same string. The era guard reads a pair as the same type when they print the
# same, and as a retype when they do not.
RSpec.describe Hecks::Runtime::EraGuard, ".uncovered_attributes type representations" do
  let(:attribute) { Struct.new(:name, :type) }
  let(:container) do
    Struct.new(:name, :attributes) do
      def attribute(name) = attributes.find { |member| member.name == name }
    end
  end
  let(:aggregate) do
    Struct.new(:attributes, :value_objects, :entities) do
      def attribute(name) = attributes.find { |member| member.name == name }
      def value_object(name) = value_objects.find { |vo| vo.name == name }
    end
  end

  def reference(name) = Hecks::Bluebook::Reference.new(name)

  def money(member_type) = container.new("Money", [attribute.new(:cents, member_type)])

  def side(type, value_object = nil)
    aggregate.new([attribute.new(:field, type)], [value_object].compact, [])
  end

  def drift(held, current)
    described_class.uncovered_attributes(side(*held), side(*current), nil)
  end

  it "reports no drift for the same scalar as a string, and for a scalar as a symbol", :aggregate_failures do
    expect(drift(["String"], ["String"])).to eq([])
    expect(drift(["Integer"], [:Integer])).to eq([])
  end

  it "reports no drift for a reference held as its string and declared as the object", :aggregate_failures do
    expect(drift(["Reference<Target>"], [reference("Target")])).to eq([])
    expect(drift(["Reference<Target>"], [reference("Hecks::Target")])).to eq([])
  end

  it "reports a retype between scalars" do
    expect(drift(["String"], ["Integer"])).to eq(["field"])
  end

  it "reports a reference that now points at another aggregate, or became a scalar", :aggregate_failures do
    expect(drift(["Reference<Target>"], [reference("Other")])).to eq(["field"])
    expect(drift(["Reference<Target>"], ["String"])).to eq(["field"])
  end

  it "reports no drift for a value object whose members are the same, however they are spelled", :aggregate_failures do
    expect(drift(["Money", money("Integer")], ["Money", money(:Integer)])).to eq([])
    expect(drift(["Money", money("Reference<Target>")], ["Money", money(reference("Target"))])).to eq([])
  end

  it "reports a value object member that changed type, as a dotted path", :aggregate_failures do
    expect(drift(["Money", money("Integer")], ["Money", money("String")])).to eq(["field.cents"])
    expect(drift(["Money", money("Reference<Target>")], ["Money", money(reference("Other"))])).to eq(["field.cents"])
  end
end
