# The verdict an era proof reads from one rehearsal outcome (`rehearsal_run.rehearsal_outcome`).
# A would_mint whose minting is none is a shape that stands: no_change. A would_mint that moves
# the shape, and no_change, pass. Every other verdict, and a missing one, fails. Run with `jq -e`:
# the exit status is 0 only for a pass.
def gate_verdict:
  if type == "array" then (.[0] // {}) else . end
  | if .verdict == "would_mint" and .minting == "none" then "no_change" else (.verdict // "missing") end;

gate_verdict as $v | ["would_mint", "no_change"] | any(. == $v)
