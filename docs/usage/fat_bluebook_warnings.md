# Fat Bluebook Warnings

Soft validation warnings that help you spot domains that may need splitting into bounded contexts.

## Aggregate Count Warning

Fires when a domain has more than 7 aggregates.

```bash
$ hecks-life validate my_fat_domain.bluebook
  WARNING: Domain MyFatDomain has 11 aggregates — consider splitting into bounded contexts
VALID — MyFatDomain (11 aggregates)
```

The domain still passes as VALID -- this is advisory only.

## Mixed Concerns Warning

Fires when a domain with 5+ aggregates has disconnected clusters -- aggregates with no references or policy wiring between them.

```bash
$ hecks-life validate mixed_domain.bluebook
  WARNING: Aggregates Order and Formula have no references between them — they may belong in separate bounded contexts
VALID — MixedDomain (6 aggregates)
```

Two aggregates are considered "connected" if:
- One has a `reference_to` pointing at the other
- A policy wires an event from one to a command in the other

Only checked for domains with 5 or more aggregates (small domains are naturally sparse).

## Splitting a Fat Domain

Use the standard Hecks project layout with one bluebook per bounded context:

```
my_project/
  hecks/
    formulation.bluebook
    catalog.bluebook
    manufacturing.bluebook
  hecksagon.hec
  world.hec
```

Cross-domain policies use `across "OtherDomain"` to declare the wiring:

```ruby
policy "ReserveOnOrder" do
  on "OrderPlaced"
  across "Inventory"
  trigger "ReserveStock"
end
```
