# Session Images — Save and Restore Workshop State

Session images let you snapshot the current state of a workshop and restore
it later. This is useful for checkpointing work, switching between domain
experiments, or resuming a session across restarts.

## Saving an Image

```ruby
workshop = Hecks.workshop("Pizzas")
workshop.aggregate "Pizza" do
  attribute :name, String
  command "CreatePizza" do
    attribute :name, String
  end
end

# Save with default label (domain name)
workshop.save_image
# => Saved image: .hecks/images/pizzas.heckimage

# Save with a custom label
workshop.save_image("before-refactor")
# => Saved image: .hecks/images/before_refactor.heckimage
```

## Restoring an Image

```ruby
workshop = Hecks.workshop("Pizzas")
workshop.restore_image
# => Restored image: .hecks/images/pizzas.heckimage (captured 2026-04-01 12:00:00 -0700)

workshop.aggregates  # => ["Pizza"]
workshop.describe    # shows the full domain as it was when saved
```

Restore a named image:

```ruby
workshop.restore_image("before-refactor")
```

## Listing Saved Images

```ruby
workshop.list_images
# => [".hecks/images/before_refactor.heckimage", ".hecks/images/pizzas.heckimage"]
```

## In the REPL

All image commands are available directly in the console:

```
$ hecks console Pizzas
Pizza.name String
Pizza.create
save_image
save_image "checkpoint"
restore_image
restore_image "checkpoint"
list_images
```

## File Format

Images are stored as human-readable `.heckimage` files containing a metadata
header and the DSL source:

```ruby
# Hecks Session Image
# Domain: Pizzas
# Captured: 2026-04-01T12:00:00-07:00
# Custom verbs:

Hecks.domain "Pizzas" do
  aggregate "Pizza" do
    attribute :name, String
    command "CreatePizza" do
      attribute :name, String
    end
  end
end
```

## Storage

Images are saved to `.hecks/images/` by default. Add `.hecks/` to your
`.gitignore` if you don't want to track them, or commit them for shared
checkpoints.
