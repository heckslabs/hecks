# hecks diff — Show Changes Since Last Build

Compare the current domain definition against the last saved snapshot to see what has changed structurally or behaviorally.

## Prerequisites

You must have run `hecks build` at least once to create a baseline snapshot. The snapshot is saved to `db/hecks_snapshot.json` by default.

## Usage

```bash
$ hecks diff --domain ./BookshelfBluebook
```

## Example output — no changes

```
No changes detected.
```

## Example output — with changes

```
3 changes detected:

  + Added command: Withdraw
  - Removed command: Deposit
  + Added validation: Account.balance
1 breaking change!
```

Breaking changes (removals of aggregates, attributes, commands, value objects, or entities) are shown in red. Additions are shown in green.

## Options

| Flag | Description |
|------|-------------|
| `--domain PATH` | Path to the domain file or gem name |
| `--version VERSION` | Domain version (optional) |

## Workflow

```bash
# 1. Build a baseline
$ hecks build --domain ./BookshelfBluebook

# 2. Edit the Bluebook
# ...make changes...

# 3. Check what changed
$ hecks diff --domain ./BookshelfBluebook

# 4. Generate a migration if needed
$ hecks migrate --domain ./BookshelfBluebook
```

## Change kinds detected

| Kind | Breaking |
|------|---------|
| add_aggregate | No |
| remove_aggregate | Yes |
| add_attribute | No |
| remove_attribute | Yes |
| add_command | No |
| remove_command | Yes |
| add_value_object | No |
| remove_value_object | Yes |
| add_entity | No |
| remove_entity | Yes |
| add_policy / remove_policy / change_policy | No |
| add_validation / remove_validation | No |
| add_query / remove_query | No |
| add_scope / remove_scope | No |
| add_specification / remove_specification | No |

See also: [DomainDiff Ruby API](domain_diff.md) for programmatic diffing.
