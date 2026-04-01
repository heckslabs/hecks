# Specs for ActiveHecks::DomainModelCompat edge cases
#
# Uses anonymous classes — no domain DSL required. Covers fallback attribute
# introspection, timestamp inclusion, id deduplication, and serialization.
#
require "spec_helper"
require "rails_spec_helper"

RSpec.describe "ActiveHecks::DomainModelCompat (edge cases)" do
  let(:base_class) do
    klass = Class.new do
      def initialize(name:)
        @name = name
      end
      attr_reader :name
    end
    klass.include(ActiveHecks::DomainModelCompat)
    klass
  end

  it "attributes falls back to initialize parameters when hecks_attributes is absent" do
    obj = base_class.new(name: "test")
    expect(obj.attributes).to eq("name" => "test")
  end

  it "attributes includes timestamps when the object responds to them" do
    klass = Class.new do
      def initialize; end
      def created_at = Time.now
      def updated_at = Time.now
    end
    klass.include(ActiveHecks::DomainModelCompat)

    obj = klass.new
    attrs = obj.attributes
    expect(attrs).to have_key("created_at")
    expect(attrs).to have_key("updated_at")
  end

  it "attributes does not duplicate id when hecks_attributes lists id" do
    klass = Class.new do
      def initialize(id:)
        @id = id
      end
      attr_reader :id

      def self.hecks_attributes
        [Hecks::RuntimeAttributeDefinition.new(name: :id)]
      end
    end
    klass.include(ActiveHecks::DomainModelCompat)

    obj = klass.new(id: "abc-123")
    attrs = obj.attributes
    expect(attrs.keys.count("id")).to eq(1)
    expect(attrs["id"]).to eq("abc-123")
  end

  it "#read_attribute_for_serialization delegates to the attribute reader" do
    obj = base_class.new(name: "delegate-test")
    expect(obj.read_attribute_for_serialization(:name)).to eq("delegate-test")
  end
end
