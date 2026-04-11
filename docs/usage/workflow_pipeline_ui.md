# Workflow Pipeline UI

Aggregates with a `lifecycle` block render as visual step pipelines in the hecks-life web UI.

## How it works

1. **Start the server** with one or more bluebook domains:

```bash
hecks-life serve path/to/hecks/ 3100
```

2. **Open a domain** in your browser at `http://localhost:3100/domains/your_domain`.

3. Each aggregate with a lifecycle shows a horizontal pipeline instead of flat badges:
   - The **default state** is highlighted in gold (first step)
   - Subsequent states are connected with arrows
   - **Commands** appear under the state they transition into
   - Commands with **givens** (preconditions) are dimmed with an amber warning showing the requirement

## Per-module fixture tables

Fixture records now appear inline inside each module card on the Build tab, filtered by aggregate name. No need to switch to the Records tab to see data for a specific aggregate.

## Example bluebook lifecycle

```
aggregate Formula {
  lifecycle status {
    default: draft
    CreateFormula -> draft
    SubmitForReview -> under_review
    ApproveFormula -> approved { given status == "under_review" }
  }
}
```

This renders as: `draft -> under_review -> approved`, with `CreateFormula` under the draft step, `SubmitForReview` under under_review, and `ApproveFormula` (dimmed, with precondition) under approved.
