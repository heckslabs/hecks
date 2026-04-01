# Turbo Streams

Hecks + Turbo Streams gives you real-time, no-reload UIs with no custom JavaScript.

## How Forms Work

With Turbo installed (via `active_hecks:init`), Turbo Drive intercepts all form submissions. No page reload. Controllers respond with `format.turbo_stream` to update the DOM in place.

```ruby
# Controller
def create
  @pizza = Pizza.create(name: params[:name])
  respond_to do |format|
    format.turbo_stream
    format.html { redirect_to pizzas_path }
  end
end
```

```erb
<%# create.turbo_stream.erb %>
<%= turbo_stream.append "pizzas" do %>
  <%= render partial: "pizza", locals: { pizza: @pizza } %>
<% end %>
```

The `format.html` fallback handles non-Turbo requests (curl, API clients).

## Clearing Forms After Submit

Replace the form with a fresh copy:

```erb
<%= turbo_stream.replace "new-pizza-form" do %>
  <%= form_with url: pizzas_path, id: "new-pizza-form" do |f| %>
    <%= f.text_field :name %>
    <%= f.submit %>
  <% end %>
<% end %>
```

## Removing Elements

```erb
<%= turbo_stream.remove "pizza_#{@pizza_id}" %>
```

## Preserving Across Navigation

Use `data-turbo-permanent` to keep an element alive across Turbo Drive page navigations:

```erb
<div id="hecks-live" data-turbo-permanent>
  <%= turbo_stream_from "hecks_live_events" %>
  <div id="event-feed"></div>
</div>
```

This keeps the ActionCable WebSocket connection and event history alive across page navigations.
