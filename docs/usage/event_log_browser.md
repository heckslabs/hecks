# Event Log Browser

Browse domain events in the web explorer at `/events`.

## Quick start

```ruby
# app.rb
require "hecks"

domain = Hecks.domain "Pizzas" do
  aggregate "Pizza" do
    attribute :name, String
    command "CreatePizza" do
      attribute :name, String
    end
  end
end

Hecks.serve(domain, port: 9292)
```

Start the server and visit `http://localhost:9292/events` after executing commands.

## URL examples

```
GET /events                           # all events, newest first
GET /events?type=CreatedPizza         # filter by event type
GET /events?aggregate=Pizza           # filter by aggregate
GET /events?aggregate=Pizza&page=2    # filter + paginate
```

## JSON endpoint

Request events as JSON by setting the `Accept` header:

```bash
curl -H "Accept: application/json" http://localhost:9292/events
# => [{"type":"CreatedPizza","occurred_at":"2026-04-02T10:00:00-07:00"}, ...]
```

## EventIntrospector API

```ruby
require "hecks/extensions/web_explorer/event_introspector"

bus = runtime.event_bus
ei = Hecks::WebExplorer::EventIntrospector.new([bus])

ei.all_entries                          # newest first
ei.all_entries(type_filter: "Created")  # filter by type
ei.event_types                          # => ["CreatedPizza", "PlacedOrder"]
ei.aggregate_types                      # => ["Pizza", "Order"]
```

## Paginator API

```ruby
require "hecks/extensions/web_explorer/paginator"

page = Hecks::WebExplorer::Paginator.new(items, page: 2, per_page: 25)
page.items        # current page slice
page.total_pages  # total number of pages
page.current      # current page number
page.next_page    # nil if on last page
page.previous_page # nil if on first page
```

## Features

- Filter bar with event type and aggregate dropdowns
- Table with timestamp, event type badge, aggregate name, expandable payload
- Pagination (25 events per page)
- "Events" link in sidebar navigation under System group
- JSON endpoint preserved (via Accept header content negotiation)
