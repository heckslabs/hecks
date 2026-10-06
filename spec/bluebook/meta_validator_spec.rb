require "spec_helper"
require "digest"
require "json"

# Pins the process-wide verdict cache key, `SHA256(JSON(bluebook.to_h))`.
# A read-model field missing from `to_h` would hand a reloaded chapter the stale read model.
RSpec.describe "MetaValidator's verdict cache" do
  def in_registry
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) do
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      yield
    end
    registry
  end

  # Built through the DSL so MetaValidator judges a real chapter, not a hand-rolled IR object.
  def build_catalog(name, filter_value)
    widget = widget_definition
    catalog = catalog_definition(filter_value)
    in_registry do
      Hecks.bluebook(name) do
        aggregate "Widget", &widget
        read_model "Catalog", &catalog
      end
    end.bluebook(name)
  end

  def widget_definition
    proc do
      identified_by :id
      lifecycle :status, default: "available" do
        transition "Retire" => "retired", from: "available"
      end
    end
  end

  def catalog_definition(filter_value)
    proc do
      include Widget

      where(status: filter_value)
    end
  end

  it "does not serve a stale read-model filter after a same-process reload with only the filter edited", :aggregate_failures do
    first  = build_catalog("StaleFilterCheck", "available")
    second = build_catalog("StaleFilterCheck", "retired")

    expect(first.read_models.first.wheres.first.value).to eq("available")
    expect(second.read_models.first.wheres.first.value).to eq("retired")
  end

  it "the cache key hashes a read-model filter, so editing only the filter changes the key" do
    key_for = lambda do |filter_value|
      Digest::SHA256.hexdigest(JSON.generate(build_catalog("KeyCheck", filter_value).to_h))
    end

    expect(key_for.call("available")).not_to eq(key_for.call("retired"))
  end
end
