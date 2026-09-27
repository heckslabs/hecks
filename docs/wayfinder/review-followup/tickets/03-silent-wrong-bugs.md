---
type: grilling
status: open
blocked_by: [02-research-silent-wrong-status]
claimed_by:
---

# Silent-wrong bugs: refuse, fix, or both

## Question

The project's thesis is refuse deterministically rather than drift quietly, yet the two
documented defects drift quietly. For each: does it refuse at boot or seal time, get fixed, or
both, and in which order? Where does the refusal live (one place, on the fixed dispatch path),
how does the Rust runtime stay in agreement, and what test would make a future silent-wrong
construct fail the suite? Note `hecks model_check --profile client` already refuses three
constructs; say whether these join that list.

## Answer
