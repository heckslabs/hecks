# Governance Guard

General-purpose governance checker that validates domain operations against
declared world concerns. Entry-point agnostic -- works from CLI, HTTP, REPL,
MCP, or workshop.

## Ruby API

```ruby
domain = Hecks.domain "Health" do
  world_concerns :privacy, :consent, :security

  actor "Doctor"

  aggregate "Patient" do
    attribute :ssn, String, pii: true, visible: false
    command "UpdateRecord" do
      attribute :notes, String
      actor "Doctor"
    end
  end
end

result = Hecks::GovernanceGuard.new(domain).check
result.passed?      # => true
result.violations   # => []
result.suggestions  # => []
```

## Checking a domain with violations

```ruby
domain = Hecks.domain "Broken" do
  world_concerns :transparency, :privacy

  aggregate "Patient" do
    attribute :ssn, String, pii: true   # visible PII -- violation
    command "DeletePatient" do
      attribute :id, String
      emits []                           # no events -- violation
    end
  end
end

result = Hecks::GovernanceGuard.new(domain).check
result.passed?      # => false

result.violations
# => [
#   { concern: :transparency, message: "Patient#DeletePatient emits no events..." },
#   { concern: :privacy, message: "Patient#ssn is PII but visible..." },
#   { concern: :privacy, message: "Patient#DeletePatient touches PII aggregate but has no actor..." }
# ]

result.suggestions
# => [
#   "Add 'emits \"EventName\"' to commands...",
#   "Add 'visible: false' to PII attributes...",
#   "Declare who can access PII: actor 'Admin'..."
# ]
```

## CLI usage

```bash
hecks validate --governance
```

Adds a Governance Check section after standard validation output showing
violations grouped by concern and actionable suggestions.

## MCP usage

The `governance_check` tool is available on the MCP server:

```json
{ "tool": "governance_check" }
```

Returns:

```json
{
  "passed": false,
  "violations": [
    { "concern": "privacy", "message": "Patient#ssn is PII but visible..." }
  ],
  "suggestions": [
    "Add 'visible: false' to PII attributes..."
  ]
}
```

## Supported concerns

| Concern        | What it checks                                        |
|----------------|-------------------------------------------------------|
| :transparency  | Every command emits at least one event                 |
| :consent       | User-like aggregate commands declare actors            |
| :privacy       | PII attributes are hidden; PII-aggregate commands have actors |
| :security      | Command actors are declared at domain level            |

## AI enrichment

When `ANTHROPIC_API_KEY` is set, the guard enriches suggestions with
AI-powered analysis. Without an API key it falls back to rule-based
suggestions automatically.
