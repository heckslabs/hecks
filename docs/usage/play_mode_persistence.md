# Play Mode Persistence

Play mode uses a full Runtime with memory adapters. After executing commands, aggregates are persisted, queryable, and countable.

## Usage

```ruby
session = Hecks.session("Demo")
session.aggregate("Cat") do
  attribute :name, String
  command("Adopt") { attribute :name, String }
end

session.play!

# Execute commands — aggregates are persisted
whiskers = session.execute("Adopt", name: "Whiskers")
session.execute("Adopt", name: "Mittens")

# Find, all, count — they work
Cat.find(whiskers.id)   # => #<Cat name="Whiskers">
Cat.all.map(&:name)     # => ["Whiskers", "Mittens"]
Cat.count               # => 2

# Class method shortcuts also persist
Cat.adopt(name: "Shadow")
Cat.count               # => 3

# Reset clears events AND repository data
session.reset!
Cat.count               # => 0
```

## Output

```
Command: Adopt
  Event: Adopted
    name: "Whiskers"

Cat.count: 2
Cat.all: ["Whiskers", "Mittens"]
Cat.find(d67296b0...): Whiskers

Cat.adopt(name: "Shadow"): Shadow
Cat.count: 3

Cleared all events and data
Cat.count: 0
```

## What changed

Play mode used to record events but not persist aggregates. Now it boots a real `Services::Runtime` with memory adapters, giving you the full command lifecycle: guard, handler, call, persist, emit, record. Same API as production, just in-memory.
