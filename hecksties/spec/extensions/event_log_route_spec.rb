require "spec_helper"
require "hecks/extensions/web_explorer/event_introspector"
require "hecks/extensions/web_explorer/renderer"

RSpec.describe "Event log page rendering" do
  let(:views_dir) { File.expand_path("../../lib/hecks/extensions/web_explorer/views", __dir__) }
  let(:renderer)  { Hecks::WebExplorer::Renderer.new(views_dir) }

  # Build fake events without loading a domain.
  def make_fake_event(mod_path, type_name)
    klass = stub_const(mod_path, Class.new(Struct.new(:occurred_at, keyword_init: true)))
    klass.new(occurred_at: Time.now)
  end

  let(:alpha_event) { make_fake_event("EventPageTest::Widget::Events::CreatedWidget", "CreatedWidget") }
  let(:beta_event)  { make_fake_event("EventPageTest::Widget::Events::UpdatedWidget", "UpdatedWidget") }

  let(:bus) do
    b = Hecks::EventBus.new
    b.publish(alpha_event)
    b.publish(beta_event)
    b
  end

  let(:intro) { Hecks::WebExplorer::EventIntrospector.new(bus) }

  it "renders the events page with event type names" do
    html = renderer.render(:events,
      title: "Event Log", brand: "Test", nav_items: [],
      entries: intro.all_entries,
      event_types: intro.event_types,
      aggregate_types: intro.aggregate_types,
      selected_type: "",
      selected_aggregate: "")
    expect(html).to include("CreatedWidget")
  end

  it "renders 'No events yet' when the bus is empty" do
    empty_bus = Hecks::EventBus.new
    empty_intro = Hecks::WebExplorer::EventIntrospector.new(empty_bus)
    html = renderer.render(:events,
      title: "Event Log", brand: "Test", nav_items: [],
      entries: empty_intro.all_entries,
      event_types: [],
      aggregate_types: [],
      selected_type: "",
      selected_aggregate: "")
    expect(html).to include("No events yet")
  end

  it "shows event count in heading" do
    html = renderer.render(:events,
      title: "Event Log", brand: "Test", nav_items: [],
      entries: intro.all_entries,
      event_types: intro.event_types,
      aggregate_types: intro.aggregate_types,
      selected_type: "",
      selected_aggregate: "")
    expect(html).to include("2 events")
  end
end
