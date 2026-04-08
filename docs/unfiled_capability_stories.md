# Unfiled Capability Stories

Linear free tier limit hit. File these when capacity is available.

## Data & Storage

### :snapshots — Periodic aggregate state snapshots
Priority: Low. Fast replay by loading last snapshot + events since. Pairs with :event_store.

### :export — CSV/JSON/PDF export of aggregate collections
Priority: Low. Export any aggregate's repository. Served at /export/:aggregate.:format when paired with :http.

## Background & Scheduling

### :workflow_engine — Multi-step approval workflows
Priority: Low. Branching, timeout, escalation. Visual workflow editor in Appeal. Declared in Bluebook DSL.

## AI & Intelligence

### :anomaly — Detect unusual patterns in event streams
Priority: Low. Statistical anomaly detection on event frequency/timing. Alert via events.

### :copilot — AI pair-programming for the domain
Priority: Medium. Suggest commands, find patterns, explain events. Context-aware from domain IR. Pairs with :chat_agent.

## Security & Compliance

### :gdpr — Data subject access requests
Priority: Low. Export all data for a user (SAR). Right to deletion. Walks all aggregates with PII tag.

### :rbac — Role-based access control
Priority: Medium. Hierarchical roles, permissions, inheritance. Beyond hecksagon gates. Middleware on command bus.

### :signing — Cryptographic signing of events
Priority: Low. Tamper-proof event log. Ed25519 signatures on each event. Verify chain integrity.

## Developer Experience

### :docs — Auto-generated API docs from domain IR
Priority: Medium. Served at /docs when paired with :http or :static_assets. Markdown/HTML from aggregates, commands, events.

### :playground — Browser-based command executor
Priority: Low. Auto-generated forms from command attributes. Execute and see results. Pairs with :webapp.

### :profiler — Command execution profiling
Priority: Low. Middleware on command bus. Find slow commands, N+1 patterns. Report per-command latency.

### :test_factory — Generate test fixtures from Bluebook
Priority: Medium. Factory Bot-style factories auto-generated from aggregate definitions. Valid default values from attribute types.

### :contract_testing — Consumer-driven contract tests between domains
Priority: Low. Verify event schemas between producer and consumer domains. Auto-generated from IR.

## Infrastructure & Multi-tenancy

### :multi_tenant — Row-level or schema-level tenancy
Priority: High. Tenant context flows through commands. Automatic scoping on repositories. World config for strategy.

### :feature_flags — Toggle commands/aggregates per tenant
Priority: Medium. Enable/disable specific commands or entire aggregates. Runtime toggle, no redeploy.

### :versioning — API versioning with migration paths
Priority: Low. Multiple domain versions running simultaneously. Migration functions between versions.

### :canary — Route percentage of commands to new version
Priority: Low. Gradual rollout of domain changes. Configurable percentage. Pairs with :versioning.

### :circuit_breaker — Fail-fast on external dependency failures
Priority: Medium. Middleware on command bus. Open/half-open/closed states. World config for thresholds.

### :presence — Track connected users
Priority: Low. "3 users viewing Pizza aggregate." Pairs with :websocket. Broadcasts presence events.

### :locking — Pessimistic locks on aggregates
Priority: Low. "Order #5 is being edited by Alice." Lock/unlock commands. Timeout-based auto-release.
