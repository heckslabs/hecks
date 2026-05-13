# ProjectManagement Capability

Domain-aware project management. Every feature links to a bluebook domain via DomainLink.

## Location

```
hecks_conception/capabilities/project_management/project_management.bluebook
```

## Validate

```bash
storehouse validate capabilities/project_management/project_management.bluebook
```

## Aggregates

- **Feature** — a thing to build. Lifecycle: backlog -> prioritized -> in_progress -> completed | deferred | cancelled
- **Sprint** — a focused work period. Lifecycle: planning -> active -> completed -> reviewed
- **Priority** — backlog rank with reason
- **Dependency** — one feature blocks another
- **Milestone** — groups features toward a checkpoint
- **DomainLink** — links features to bluebook domains (domain-awareness is the key differentiator)
- **WorkLog** — time and commit tracking

## Create a Feature

```
CreateFeature(title: "Add search to CLI", category: "feature", priority: "high", domain_name: "Cli")
```

Auto-triggers: LinkToDomain (via LinkOnCreate policy), PrioritizeFeature (via PrioritizeOnCreate policy).

## Track a Sprint

```
PlanSprint(name: "Week 15", goal: "Ship CLI projection", start_date: "2026-04-14", end_date: "2026-04-18")
AddToSprint(feature_id: "...", sprint_id: "...")
StartSprint(sprint_id: "...")
```

## Log Work

```
LogWork(feature_id: "...", description: "Implemented search command", duration_minutes: 45)
LinkCommit(work_log_id: "...", commit_sha: "abc123")
```
