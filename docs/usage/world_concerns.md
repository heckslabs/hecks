# World Concerns

Declare ethical and governance aspirations for your domain. Each concern activates
validation rules that check your model for alignment.

## DSL

```ruby
Hecks.domain "Healthcare" do
  world_concerns :transparency, :consent, :privacy, :security

  actor "Doctor"
  actor "Admin"

  aggregate "Patient" do
    attribute :name, String
    attribute :ssn, String, pii: true, visible: false

    command "CreatePatient" do
      attribute :name, String
      attribute :ssn, String
      actor "Admin"
    end

    command "UpdateRecord" do
      attribute :notes, String
      actor "Doctor"
    end
  end
end
```

## Available Concerns

### `:transparency`

Every command must emit at least one domain event. Silent mutations violate
transparency because observers and audit logs cannot track changes.

**Violation:** `emits []` on a command.

### `:consent`

Commands on user-like aggregates (User, Account, Member, Customer, Patient,
Person, Profile) must declare at least one `actor`. Without an actor, there is
no record of who initiated the action.

### `:privacy`

PII attributes (marked `pii: true`) must also be `visible: false` so they are
hidden from generated UIs. Commands on aggregates that contain PII must declare
an actor for audit trails.

### `:security`

Command-level actors must be declared at the domain level with `actor "Name"`.
This prevents dangling or misspelled role references.

## World Concerns Report

When world concerns are declared, `hecks validate` prints a **World Concerns Report**
after the standard validation output. Each declared concern gets a PASS/FAIL status,
and any violations are listed.

```
$ hecks validate

Domain is valid

Aggregates:
  Patient
    Attributes:     name, ssn
    Commands:       CreatePatient, UpdateRecord

World Concerns Report
  Concerns declared: transparency, consent, privacy, security
  [PASS] transparency
  [PASS] consent
  [PASS] privacy
  [PASS] security
```

When violations exist:

```
$ hecks validate

Domain validation failed:
  - Transparency: Record#DeleteRecord emits no events. Commands must emit events so changes are observable.
  - Consent: Patient#UpdateRecord has no actor. Commands on user-like aggregates must declare who initiates them.

World Concerns Report
  Concerns declared: transparency, consent
  [FAIL] transparency
  [FAIL] consent

  Violations:
    - Transparency: Record#DeleteRecord emits no events. Commands must emit events so changes are observable.
    - Consent: Patient#UpdateRecord has no actor. Commands on user-like aggregates must declare who initiates them.
```

The report is also available programmatically via `Validator#world_concerns_report`:

```ruby
validator = Hecks::Validator.new(domain)
validator.valid?
report = validator.world_concerns_report
# => { concerns_declared: [:transparency], violations: [...],
#      passing_concerns: [], failing_concerns: [:transparency] }
```

## No Concerns, No Rules

If you do not declare `world_concerns`, none of these rules fire. They are opt-in.
The World Concerns Report is omitted when no concerns are declared.
