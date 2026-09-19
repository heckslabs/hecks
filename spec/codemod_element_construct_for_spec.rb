require "spec_helper"
require "hecks/codemod"

RSpec.describe Hecks::Codemod, ".element_construct_for" do
  Attribute = Struct.new(:name, :list, :type) do
    def list? = list
  end
  Construct = Struct.new(:hecks_name, :attributes, :value_objects, :entities)

  def named(hecks_name) = Struct.new(:hecks_name).new(hecks_name)

  it "answers nil when the field names no attribute" do
    construct = Construct.new("Box", [], [], [])
    expect(described_class.element_construct_for(construct, :tags)).to be_nil
  end

  it "answers nil when the field is not a list" do
    attr = Attribute.new(:tags, false, "Tag")
    construct = Construct.new("Box", [attr], [named("Tag")], [])
    expect(described_class.element_construct_for(construct, :tags)).to be_nil
  end

  it "finds the value object a list_of attribute names" do
    attr = Attribute.new(:tags, true, "Tag")
    tag = named("Tag")
    construct = Construct.new("Box", [attr], [tag], [])
    expect(described_class.element_construct_for(construct, :tags)).to equal(tag)
  end

  it "finds the entity a list_of attribute names" do
    attr = Attribute.new(:entries, true, "LedgerEntry")
    entry = named("LedgerEntry")
    construct = Construct.new("Box", [attr], [], [entry])
    expect(described_class.element_construct_for(construct, :entries)).to equal(entry)
  end

  it "raises rather than silently favoring the value object when a same-named entity also matches" do
    attr = Attribute.new(:tags, true, "Tag")
    construct = Construct.new("Box", [attr], [named("Tag")], [named("Tag")])
    expect { described_class.element_construct_for(construct, :tags) }.to raise_error(/ambiguous/)
  end
end
