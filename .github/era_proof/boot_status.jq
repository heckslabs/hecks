# The problems in one `era.boot_status` answer, one line per bluebook the era proof refuses. A
# bluebook passes when it is `current`, or `behind` by an implicit move the ledger records (the
# status names `move` only when it is recorded). Every other status is a problem, and its reason
# is named after it. Run with `jq -r -f`: no output means every bluebook passes.
.bluebooks | to_entries[]
  | select(((.value.status == "current") or (.value.status == "behind" and .value.move != null)) | not)
  | "\(.key): \(.value.status)" + (if .value.reason then ": \(.value.reason)" else "" end)
