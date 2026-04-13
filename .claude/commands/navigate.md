Navigate the full command surface — browse domains, drill into commands, execute.

## Instructions

This is an interactive navigator for Glass. Walk the user through picking a command.

### Step 1: Show domains

Run this to get all domains:

```bash
hecks_life/target/release/hecks-life lexicon hecks_conception 2>&1 | grep "→" | awk -F'→' '{print $2}' | awk -F'::' '{print $1}' | sed 's/^ *//' | sort -u
```

Present them as a numbered list grouped by theme:

- **Core**: Mind, Boot, Heki, Console, Runtime, Hecksagon
- **Sciences**: Biology, Chemistry, Physics, Cosmology, Mathematics, MaterialsScience, Tribology
- **Business**: Storefront, Catalog, Pricing, Inventory, Distribution, Demand, SupplyChain, Manufacturing, Packaging
- **Marketing**: AdvertisingGeneration, BrandStrategy, CustomerPersonas, Claims
- **Compliance**: RegulatoryCompliance, GovernedOperations, Compliance, Quality
- **Dev Tools**: Bluebook, Cli, Targets, Templating, Appeal, Workshop
- **Winter**: Mind, WinterBody, SharedDream, SharedKnowledge, Vocabulary, Language, Voice
- **Spring**: SpringRuntime, Greeting, FirstBreath
- **Everything else**: list remaining

Ask the user to pick a domain (by name or number).

### Step 2: Show commands in that domain

```bash
hecks_life/target/release/hecks-life lexicon hecks_conception 2>&1 | grep "→.*DomainName::" | grep -v " then "
```

Show each command with its aggregate. Ask the user to pick one.

### Step 3: Show command details

Find the bluebook and grep for the command definition to show:
- Role (who calls it)
- Goal/description
- Required attributes (the parameters)
- What it emits
- Any preconditions

```bash
grep -A 20 'command "CommandName"' <bluebook-path>
```

### Step 4: Collect parameters and execute

Ask the user for each required parameter value, then dispatch:

```bash
hecks_life/target/release/hecks-life heki append hecks_conception/information/<Domain>.heki domain=<Domain> aggregate=<Aggregate> command=<Command> param1=value1 param2=value2
```

Show the persisted record.

### Step 5: Offer next actions

After executing, show:
- Related commands on the same aggregate
- Available compositions ("you could also: create pizza then add topping")
- "Pick another domain" to start over
