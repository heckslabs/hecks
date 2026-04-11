# Serve Web App

`hecks-life serve` generates a full Tailwind-styled web application from Bluebook domains. One command, one port — both JSON API and HTML UI.

## Usage

```bash
# Serve all bluebooks in a directory
hecks-life serve path/to/hecks/ 3100

# Open in browser
open http://localhost:3100
```

## Routes

| Method | Path | Response |
|--------|------|----------|
| GET | `/` | HTML dashboard with all domains |
| GET | `/domains/:name` | HTML detail page for one domain |
| GET | `/domains` | JSON list of domain names |
| POST | `/domains/:name/dispatch` | JSON command dispatch |
| GET | `/domains/:name/domain` | JSON domain structure |
| GET | `/domains/:name/aggregates/:agg` | JSON aggregate records |

## Example

```bash
# Serve Alan's engine additive business (16 domains)
hecks-life serve nursery/alans_engine_additive_business/hecks/ 3100
```

The dashboard shows domain count, module count, command count, and policy count. Click any domain to see its modules, lifecycle states, and command forms. Command forms submit via fetch and show inline results.
