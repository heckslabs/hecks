# Paragraphs

Paragraphs group aggregates into named sections within a chapter (domain).
They're an organizational tool — no runtime behavior changes, but they help
structure large chapters into focused sections.

## DSL

```ruby
Hecks.domain "Runtime" do
  paragraph "Ports" do
    aggregate "EventBus" do
      attribute :name, String
      command "Publish" do
        attribute :event_name, String
      end
    end

    aggregate "CommandBus" do
      attribute :name, String
      command "Dispatch" do
        attribute :command_name, String
      end
    end
  end

  paragraph "EventSourcing" do
    aggregate "EventStore" do
      attribute :stream_id, String
      command "Append" do
        attribute :stream_id, String
        attribute :event, String
      end
    end
  end
end
```

## IR

Paragraphs are tracked on the Domain IR as `Structure::Paragraph` nodes:

```ruby
domain = Hecks::Chapters::Runtime.definition
domain.paragraphs.map(&:name)
# => ["Ports", "EventSourcing"]

domain.paragraphs.first.aggregates.map(&:name)
# => ["EventBus", "CommandBus"]
```

Aggregates defined inside a paragraph block are still part of the domain's
top-level `aggregates` collection — paragraphs are purely organizational.

## Self-describing chapters

The Bluebook chapter itself uses paragraphs to organize its 50+ aggregates:

```ruby
# bluebook/lib/hecks/chapters/bluebook.rb
require_relative "bluebook/structure"
require_relative "bluebook/behavior"

StructureParagraph.define(b)   # 15 IR structure nodes
BehaviorParagraph.define(b)    # 12 behavior nodes
NamesParagraph.define(b)       # 5 naming nodes
ToolingParagraph.define(b)     # 5 compiler tools
```
