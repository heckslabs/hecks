require "spec_helper"
require "hecks/extensions/web_explorer/event_introspector"
require "hecks/extensions/web_explorer/paginator"
require "hecks/extensions/web_explorer/renderer"

RSpec.describe "Event log page rendering" do
  let(:views_dir) { File.expand_path("../../lib/hecks/extensions/web_explorer/views", __dir__) }
  let(:renderer)  { Hecks::WebExplorer::Renderer.new(views_dir) }

  def make_fake_event(mod_path, _type_name)
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

  let(:intro) { Hecks::WebExplorer::EventIntrospector.new([bus]) }

  def render_events_page(intro_obj, renderer_obj)
    entries = intro_obj.all_entries
    pager = Hecks::WebExplorer::Paginator.new(entries)
    items = pager.items.map do |e|
      ts = e[:occurred_at] ? e[:occurred_at].strftime("%Y-%m-%d %H:%M:%S") : "---"
      e.merge(occurred_at_display: ts, payload_display: e[:payload].map { |k, v| "#{k}: #{v}" }.join("\n"))
    end
    renderer_obj.render(:events,
      title: "Event Log", brand: "Test", nav_items: [],
      items: items, total_count: pager.total_count,
      event_types: intro_obj.event_types, aggregate_types: intro_obj.aggregate_types,
      type_filter: "", aggregate_filter: "",
      current_page: pager.current, total_pages: pager.total_pages,
      prev_page: pager.previous_page, next_page_num: pager.next_page,
      page_query: ->(pg) { "page=#{pg}" })
  end

  it "renders the events page with event type names" do
    html = render_events_page(intro, renderer)
    expect(html).to include("CreatedWidget")
  end

  it "renders empty state when the bus is empty" do
    empty_intro = Hecks::WebExplorer::EventIntrospector.new([Hecks::EventBus.new])
    html = render_events_page(empty_intro, renderer)
    expect(html).to include("No events recorded yet")
  end

  it "shows event count in heading" do
    html = render_events_page(intro, renderer)
    expect(html).to include("Event Log (2)")
  end
end
