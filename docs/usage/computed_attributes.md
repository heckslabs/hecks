# Computed Attributes

Computed attributes are derived values calculated from other attributes on an
aggregate. They're not stored in the database — they exist only as methods on
the generated Ruby class.

## DSL

```ruby
Hecks.domain "RealEstate" do
  aggregate "Parcel" do
    attribute :area, Float
    attribute :density, Float

    computed :lot_size do
      area / 43560.0
    end

    computed :total_units do
      (area * density).ceil
    end

    command "CreateParcel" do
      attribute :area, Float
      attribute :density, Float
    end
  end
end
```

## Generated Ruby

The `computed` block body becomes a method on the aggregate class:

```ruby
class Parcel
  include Hecks::Model

  attribute :area
  attribute :density

  # Computed attributes -- derived values, not stored
  def lot_size
    area / 43560.0
  end

  def total_units
    (area * density).ceil
  end
end
```

## Usage at Runtime

```ruby
parcel = Parcel.create(area: 87120.0, density: 0.5)
parcel.lot_size    # => 2.0
parcel.total_units # => 43561
```

## Web Explorer

Computed attributes appear on index and show pages with a "(computed)" label.
They are not shown on command forms since they are derived, not user-entered.

## Go Target

Go aggregates get placeholder receiver methods with a TODO comment:

```go
// LotSize -- computed attribute (TODO: implement)
func (a *Parcel) LotSize() interface{} {
    // TODO: translate computed logic from Ruby DSL
    return nil
}
```

## CLI Inspector

`hecks inspect` shows computed attributes under their own section:

```
Aggregate: Parcel
=================

  Attributes:
    area: Float
    density: Float

  Computed Attributes:
    lot_size: area / 43560.0
    total_units: (area * density).ceil
```

## MCP / AI Tooling

The `add_computed` MCP tool lets AI agents add computed attributes:

```json
{
  "tool": "add_computed",
  "arguments": {
    "aggregate": "Parcel",
    "name": "lot_size",
    "formula": "area / 43560.0"
  }
}
```

## Validation

Computed attribute names can't collide with regular attribute names. The
validator will catch this:

    Parcel: computed attribute 'area' collides with a regular attribute
