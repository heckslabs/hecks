require "tmpdir"

# A chapter whose second aggregate types an attribute with a value object the
# first aggregate declares.
#
# `Booking#site_reference` is typed `SiteReference`, a value object owned by
# `ManagedSite`. Booking declares no `SiteReference` of its own, so the
# attribute can only mean the sibling's declaration. `Booking#site` is a real
# `reference_to`, kept alongside so a spec can tell the two apart.
module SiblingValueObjectDomain
  SOURCE = <<~BLUEBOOK.freeze
    Hecks.bluebook "SiblingValueObject" do
      vision "One aggregate types an attribute with another aggregate's value object."
      core

      aggregate "ManagedSite" do
        description "Owns the SiteReference value object."
        identified_by :title
        attribute :title, SiteTitle

        value_object "SiteTitle", String
        value_object "SiteReference" do
          attribute :value, String
        end
        value_object "Tier" do
          attribute :level, Integer
        end
        value_object "Tag" do
          attribute :name, String
        end

        command "Manage" do
          role "Admin"
          goal "Manage a site"
          attribute :title, SiteTitle
          sets :title
          emits "SiteManaged"
        end
      end

      aggregate "Booking" do
        description "Books a site, naming it by ManagedSite's SiteReference."
        identified_by :label
        attribute :label, BookingLabel
        attribute :site_reference, SiteReference
        attribute :tier, Tier
        attribute :tags, list_of(Tag)
        reference_to ManagedSite, as: :site

        value_object "BookingLabel", String

        command "Book" do
          role "Admin"
          goal "Book a site"
          attribute :label, BookingLabel
          attribute :site_reference, SiteReference
          attribute :tier, Tier
          sets :label
          sets :site_reference
          sets :tier
          emits "Booked"
        end

        query "BySite" do
          attribute :site_reference, SiteReference
          where(site_reference: :site_reference)
        end

        query "BySiteDesc" do
          order_by :site_reference, :desc
        end

        query "TaggedRed" do
          where(tags: { contains: "red" })
        end

        query "TierDesc" do
          order_by :tier, :desc
        end
      end
    end
  BLUEBOOK

  # Loads the chapter into a fresh registry, ports and Memory adapter included.
  #
  # @return [Hecks::Bluebook::Chapter] the judged `SiblingValueObject` chapter
  def self.chapter
    registry = Hecks::Runtime::Registry.new
    Dir.mktmpdir("hecks-sibling-vo-") do |dir|
      path = File.join(dir, "sibling_value_object.bluebook")
      File.write(path, SOURCE)
      Hecks.with_registry(registry) do
        Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
        Kernel.load(InMemoryDomain::EXTRACTION_PORT)
        Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
        Kernel.load(InMemoryDomain::PRISM_ADAPTER)
        Kernel.load(path)
      end
    end
    registry.bluebook("SiblingValueObject")
  end
end
