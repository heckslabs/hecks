### Run the demo

```bash
ruby -I../hecks/lib app.rb
```

This boots all 5 domains, wires cross-domain events, and runs a full scenario: registers stakeholders, vendors, and models, runs risk assessments, opens compliance reviews, deploys to production, reports an incident, and shows the audit trail.

### Run the HTTP API

```bash
ruby -I../hecks/lib app.rb --serve
```

Starts a Swagger UI at `http://localhost:9292` with REST endpoints for all 14 aggregates.

### Run the MCP server

```bash
ruby -I../hecks/lib app.rb --mcp
```

Exposes all domain commands and queries as AI agent tools via the Model Context Protocol.

### Seed data

```bash
ruby -I../hecks/lib -e "require 'hecks'; %w[identity model_registry risk_assessment compliance operations].each { |n| eval(File.read(\"domains/#{n}.rb\")) }; domains = (1..5).map { Hecks.bluebooks.pop }; bus = Hecks::EventBus.new; domains.each { |d| Hecks::Runtime.new(d, event_bus: bus) }; load 'seeds.rb'"
```

Seeds 3 regulatory frameworks (EU AI Act, NIST AI RMF, ISO 42001), 5 governance policies, and 5 stakeholder roles.

### Run specs

```bash
for d in *_domain; do
  (cd $d && BUNDLE_GEMFILE=../Gemfile bundle exec rspec --order defined)
done
```

961 specs across 5 domains, all under 1 second.
