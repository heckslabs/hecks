require "spec_helper"
require "hecks/bluebook/model_check"

# The opt-in `client` profile of the model checker: refuses a construct that
# would answer wrong, changing nothing when the profile isn't requested.
RSpec.describe "the model checker's client profile" do
  SHOP = <<~BLUEBOOK.freeze
    Hecks.bluebook "ClientProfileShop" do
      vision "One owner, one widget aggregate, one read model per shape the client profile judges."
      core

      aggregate "Owner" do
        identified_by :number
        attribute :number, Number
        value_object "Number" do
          attribute :value, String
        end
        command "Enrol" do
          attribute :number, Number
        end
      end

      aggregate "Widget" do
        identified_by :number
        reference_to Owner
        attribute :number, Number
        attribute :group, Group
        value_object "Number" do
          attribute :value, String
        end
        value_object "Group" do
          attribute :name, String
        end
        command "Make" do
          attribute :number, Number
          attribute :group, Group
        end
      end

      read_model "WidgetsByGroup" do
        include Widget
        group_by :group
      end

      read_model "OwnerWidgets" do
        reference_to Owner
        include Owner
        include Widget
      end

      read_model "OwnerWidgetCount" do
        reference_to Owner
        include Owner
        include Widget
        count
      end
    end
  BLUEBOOK

  def shop_wiring(projection)
    proc do
      ClientProfileShop::Owner.persisted_by("Memory")
      ClientProfileShop::Widget.persisted_by("Memory")
      projected_by(projection) if projection
    end
  end

  def build(projection: nil)
    registry = Hecks::Runtime::Registry.new
    wiring = shop_wiring(projection)
    Hecks.with_registry(registry) do
      MemoryPorts.load!
      eval(SHOP, TOPLEVEL_BINDING, "client_profile_shop.bluebook")
      Hecks.hecksagon("ClientProfileShop", &wiring)
    end
    registry
  end

  def unprofiled(registry)
    chapter = registry.bluebooks.values.first
    Hecks::Bluebook::ModelCheck.call(chapter, hecksagon: registry.hecksagon(chapter.name))
  end

  def profiled(registry, profile: :client)
    chapter = registry.bluebooks.values.first
    Hecks::Bluebook::ModelCheck.call(chapter, hecksagon: registry.hecksagon(chapter.name), profile: profile)
  end

  describe "without the profile" do
    it "adds no finding and leaves the others as they were", :aggregate_failures do
      registry = build(projection: "SqliteProjection")
      plain = profiled(registry, profile: nil)

      expect(plain.map(&:kind).grep(/\Aclient_/)).to be_empty
      expect(plain.map(&:to_s)).to eq(unprofiled(registry).map(&:to_s))
    end

    it "refuses a profile it does not know" do
      expect { profiled(build, profile: :strict_client) }.to raise_error(ArgumentError, /unknown profile/)
    end
  end

  # A projected rooted read model is not refused: `Fuzzing::ProjectionAgreement` checks its
  # projection's answer against the in-process loop (ADR 0121).
  describe "projected read models" do
    it "refuses none, since the projection's answer is checked against the loop's" do
      expect(profiled(build(projection: "SqliteProjection")).map(&:kind).grep(/\Aclient_/)).to be_empty
    end
  end
end
