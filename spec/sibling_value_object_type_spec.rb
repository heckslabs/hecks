require "spec_helper"
require_relative "support/sibling_value_object_domain"

# An attribute typed with a value object a sibling aggregate declares is a value
# object, not a reference.
#
# The assembly offers an attribute's type to the language as the id of what it
# names: a head's id (chapter, aggregate) for a `reference_to`, a declaration's id
# (chapter, owning aggregate, name) for a value object or entity. Reading the id
# back has to tell the two apart by shape, or a value object owned by another
# aggregate comes back as `Reference<Name>` and every consumer that asks "is this
# a value object" gets the wrong answer.
RSpec.describe "an attribute typed with a sibling aggregate's value object" do
  let(:chapter) { SiblingValueObjectDomain.chapter }
  let(:booking) { chapter.aggregate("Booking") }
  let(:attribute) { booking.attribute("site_reference") }

  it "assembles to the bare value object name" do
    expect(attribute.type.to_s).to eq("SiteReference")
  end

  it "is not a reference" do
    expect(attribute.reference?).to be(false)
  end

  it "still resolves to the sibling's value object through the chapter" do
    resolved = Hecks::Runtime::Value.value_object_for(booking, attribute.type)

    expect(resolved).to be(chapter.aggregate("ManagedSite").value_object("SiteReference"))
  end

  it "keeps a real reference_to as a reference" do
    site = booking.attribute("site")

    expect([site.reference?, site.type.to_s]).to eq([true, "Reference<ManagedSite>"])
  end

  it "keeps an attribute typed with the aggregate's own value object bare" do
    expect(booking.attribute("label").type.to_s).to eq("BookingLabel")
  end

  it "carries the same type in the exported IR" do
    exported = booking.to_h[:attributes].to_h { |field| [field[:name].to_s, field[:type].to_s] }

    expect(exported).to include("site_reference" => "SiteReference", "site" => "Reference<ManagedSite>")
  end
end
