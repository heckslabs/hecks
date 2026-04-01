# The Hecks Covenant

## What This Is

This is not a terms of service. It is not a code of conduct. It is a statement of what Hecks believes about software and the world it operates in — and what that belief asks of the framework and the people who build with it.

---

## The Belief

Software affects living beings.

Not just users. Not just paying customers. The people downstream of the software, the communities it operates in, the animals and ecosystems touched by the systems it powers. Every domain model encodes values — about who matters, whose data is protected, what can be taken without consent, what gets discarded. Most frameworks treat these as the developer's problem. Hecks treats them as the framework's responsibility.

---

## The Three Root Principles

All of Hecks' world goals flow from three roots. They are not arbitrary. They map to the three ways software most commonly fails the beings it touches.

**Transparency** — the relief of ignorance.

Software built in ignorance hides how it actually works — from users, from regulators, from the developers themselves. Transparency makes the true nature of the system visible: events are observable, state changes are auditable, nothing is hidden from the people it affects. When a system is transparent, the beings it touches can see it clearly and respond to it truthfully.

**Equity** — the expression of equanimity.

Attachment in software looks like extracting engagement, maximizing retention, creating dependency. It optimizes for the system's gain at the user's expense — their time, their attention, their money, their data. Equity means the system serves without clinging. It gives and releases. It does not pull. Neither grasping nor aversion — a system in balance with the beings it serves.

**Consent** — the expression of love.

Aversion in software treats users as threats to be managed, data to be extracted, liabilities to be disclaimed. Love means the system is designed *for* the being it serves. Their autonomy is honored. Their inner life is sacred. Nothing is taken without their knowledge. Commands that affect people require an actor. Deletion requires intention. Consent is not a checkbox — it is a structural commitment.

---

## What the Framework Does

Hecks encodes these principles as defaults, validators, and invitations — not as locks.

**Defaults protect.** The secure path is the easy path. Auth is fail-closed. References are validated. Sensitive attributes can be hidden. The framework makes the compassionate choice the convenient choice.

**Validators witness.** `world_goals` declarations are checked at boot. If your structure contradicts your stated values, Hecks will tell you. Not to block you — to show you the gap between intention and reality.

**Mother Earth reviews.** After validation, a voice speaks from the perspective of the living world — calm, non-judgmental, present-tense. Not a score. Not a grade. A witness to what the domain does for the beings downstream of it.

**`hecks new` asks first.** Before a single aggregate is declared, the framework asks what the domain owes the world. The developer can skip it. But they saw the question.

---

## What the Framework Does Not Do

Hecks does not prevent harmful software from being built.

This is intentional. A framework that forced goodness would not actually be good — it would be paternalistic. It would say: we do not trust you. That is not compassion. That is control.

The design honors developers as beings with agency. The deliberate opt-out — skipping world goals, overriding a default, disabling a validator — is always available. What Hecks asks is that the choice be conscious. That it not happen by accident, by inattention, by not knowing the question existed.

When someone does declare `world_goals :consent, :privacy` — it means something. It was not the only option. They chose it anyway.

The framework is a witness, not an enforcer.

---

## The World Goals

These are the current goals available to declare. They are expressions of the three root principles in concrete, checkable form.

| Goal | Root | What it checks |
|------|------|----------------|
| `:transparency` | Transparency | All state-changing commands emit at least one event |
| `:privacy` | Consent | PII-signal attributes are marked `visible: false`; actor required on PII commands |
| `:consent` | Consent | Commands affecting user-representing aggregates declare an actor |
| `:equity` | Equity | No discriminatory attributes used as gatekeeping fields |
| `:sustainability` | Equity | No unbounded queries; data growth is bounded |
| `:security` | Transparency | Fail-closed auth, CSRF protection, reference validation enforced |

New goals will be added as the framework's understanding deepens.

---

## The Invitation

If you are building software and you have not asked what it owes the beings it touches — this is the invitation.

Not to be perfect. Not to solve every problem. Just to look clearly, declare honestly, and let the structure reflect the intention.

The beings downstream of your software are real. They will be affected by the choices you make in the domain model — by what you name, what you protect, what you require, what you expose. Hecks asks you to make those choices consciously.

That is enough.

---

*Hecks is open source. The covenant is not enforced by law or license. It is offered as a frame — a way of seeing what software is for and who it serves. Take what is useful. Leave what is not. Build well.*
