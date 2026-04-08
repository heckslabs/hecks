# AI Governance Platform

An AI governance platform built with [Hecks](https://github.com/yourorg/hecks). Five bounded contexts, 14 aggregates, and 7 application services track AI models from registration through risk assessment, compliance review, deployment, and incident management — with full audit trails, PII protection, and cross-domain event-driven policies.

Built as pure domain gems with no persistence logic baked in. Five independent domains communicate via a shared event bus.

## Quick Start

```ruby
require "hecks"

# Load and boot all 5 domains with shared event bus
domains = %w[identity model_registry risk_assessment compliance operations].map do |name|
  eval(File.read("domains/#{name}.rb"))
end
shared_bus = Hecks::EventBus.new
apps = domains.map { |d| Hecks::Runtime.new(d, event_bus: shared_bus) }

# Register a stakeholder and vendor
alice = Stakeholder.register(name: "Alice", email: "alice@gov.ai", role: "assessor", team: "risk")
openai = Vendor.register(name: "OpenAI", contact_email: "e@openai.com", risk_tier: "high")

# Register and assess a model
gpt = AiModel.register(name: "GPT-5", version: "1.0", provider_id: openai.id, description: "LLM")
assessment = Assessment.initiate(model_id: gpt.id, assessor_id: alice.id)
Assessment.submit(assessment_id: assessment.id, risk_level: "high",
  bias_score: 0.35, safety_score: 0.72, transparency_score: 0.5, overall_score: 0.52)

# Events flow: SubmittedAssessment → ClassifyRisk (auto)
gpt = AiModel.find(gpt.id)
gpt.risk_level  # => "high"
gpt.classified?  # => true

# Create policy, review, approve
policy = GovernancePolicy.create(name: "EU AI Act", description: "...", category: "regulatory")
review = ComplianceReview.open(model_id: gpt.id, policy_id: policy.id, reviewer_id: alice.id)
ComplianceReview.approve(review_id: review.id, notes: "Passed")
AiModel.approve(model_id: gpt.id)
```

## Usage

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

## Architecture

```
                    ┌─────────────────────────────────────────────┐
                    │              Model Registry                  │
Register ──► draft ──► ClassifyRisk ──► classified ──► approved    │
                                            │            │         │
                                            └──► suspended ◄──┘   │
                                                     │             │
                                                     └──► retired  │
                    └─────────────────────────────────────────────┘
                         ▲                    ▲            ▲
                         │                    │            │
              SubmittedAssessment    RejectedReview   ReportedIncident
                         │                    │         (critical)
                    ┌────┘               ┌────┘            │
                    │                    │                  │
              Risk Assessment      Compliance          Operations
```

**5 bounded contexts** communicate via domain events:

1. **Identity** — Stakeholder, AuditLog (shared kernel, listens to all)
2. **Model Registry** — AiModel, Vendor, DataUsageAgreement (reacts to assessment/compliance/incident events)
3. **Risk Assessment** — Assessment (publishes SubmittedAssessment)
4. **Compliance** — GovernancePolicy, RegulatoryFramework, ComplianceReview, Exemption, TrainingRecord (publishes RejectedReview)
5. **Operations** — Deployment, Incident, Monitoring (publishes ReportedIncident)

## Domains

### Identity (shared kernel)

| Aggregate | Purpose |
|---|---|
| **Stakeholder** | People in the system — assessors, reviewers, board members. PII-protected name and email. |
| **AuditLog** | Immutable record of governance actions. Auto-populated by cross-domain policies. |

### Model Registry

| Aggregate | Purpose |
|---|---|
| **AiModel** | Core entity. Versioned, with lifecycle: draft → classified → approved → suspended → retired. |
| **Vendor** | Third-party model providers with risk tiers and review schedules. |
| **DataUsageAgreement** | Tracks data source consent, purpose, and expiration. |

Reacts to events from other domains:
- `SubmittedAssessment` → auto-classifies model risk
- `RejectedReview` → auto-suspends model
- `ReportedIncident` (critical) → auto-suspends model

### Risk Assessment

| Aggregate | Purpose |
|---|---|
| **Assessment** | Risk scoring with bias, safety, transparency, and overall scores (0.0–1.0). |

Publishes `SubmittedAssessment` which triggers risk classification in Model Registry.

### Compliance

| Aggregate | Purpose |
|---|---|
| **GovernancePolicy** | Rules with requirements, mapped to regulatory frameworks. |
| **RegulatoryFramework** | EU AI Act, NIST AI RMF, ISO 42001 — jurisdiction and authority. |
| **ComplianceReview** | Model-vs-policy review with attachments. Approve, reject, or request changes. |
| **Exemption** | Temporary waivers from policy requirements with expiration. |
| **TrainingRecord** | Tracks who completed training on which policy. |

Publishes `RejectedReview` which triggers model suspension in Model Registry.

### Operations

| Aggregate | Purpose |
|---|---|
| **Deployment** | Where approved models run — environment, audience, endpoint. |
| **Incident** | Bias, safety, privacy, and performance incidents with full lifecycle. |
| **Monitoring** | Post-deployment metrics with threshold breach detection. |

Publishes `ReportedIncident` which triggers model suspension (if critical) in Model Registry.

## Application Services

### ModelOnboardingService

Orchestrates model registration: creates the model, initiates a risk assessment, creates data usage agreements, and opens compliance reviews against all active policies.

```ruby
result = ModelOnboardingService.onboard(
  name: "GPT-5", version: "1.0", provider_id: vendor.id,
  description: "Large language model", assessor_id: alice.id,
  data_sources: [{ source: "CommonCrawl", purpose: "Pre-training", consent: "public_domain" }]
)
result.model       # => AiModel
result.assessment   # => Assessment
result.agreements   # => [DataUsageAgreement]
result.reviews      # => [ComplianceReview]
```

### ComplianceCheckService

Read-only compliance report. Checks a model against all active policies, considers exemptions, verifies reviewer training, flags open incidents.

```ruby
report = ComplianceCheckService.check(model_id: gpt.id)
report.compliant?         # => false
report.gaps               # => [{ policy: ..., status: "rejected" }, ...]
report.incidents          # => [Incident]
report.exemptions         # => [Exemption]
```

### RiskDashboardService

Cross-domain dashboard aggregation.

```ruby
dashboard = RiskDashboardService.summary
dashboard.models_by_risk       # => { "high" => 1, "low" => 1 }
dashboard.open_incidents       # => [Incident]
dashboard.active_deployments   # => [Deployment]
dashboard.expiring_agreements  # => [DataUsageAgreement]
```

### PeriodicReviewService

Scheduled checks for expired agreements, overdue policy reviews, stale assessments, expiring exemptions, and vendor reviews. Supports auto-revocation.

```ruby
actions = PeriodicReviewService.run(auto_revoke: true)
actions.expired_agreements    # found and revoked
actions.vendor_reviews_due    # vendors needing reassessment
```

### IncidentResponseService

Orchestrates the full incident lifecycle.

```ruby
resolved = IncidentResponseService.full_resolution(
  incident_id: incident.id,
  resolution: "Retrained model with balanced dataset",
  root_cause: "Training data gender imbalance"
)
resolved.status  # => "closed"
```

### NotificationService

Event-driven routing with urgency levels and recipient mapping.

### FullApprovalService

Approves both the compliance review and the model in one call.

## License

MIT
