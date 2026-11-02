# Reads what `Operation.run!` kept of a ShardPlan.Request run and prints the story as markdown:
# each event in order, the policy that reacted to it and the command that policy triggered, then
# what the plan came to. The CI plan jobs write it to the job summary and upload it.
.state.output | fromjson
| . as $report
| ($report.events | last) as $planned
| ["### Shard plan: \($planned.payload.name.value // "?")", "",
   "| # | event | policy that reacted | command it triggered |", "|---|---|---|---|"]
  + ($report.events | to_entries | map(
      .key as $i | .value as $event
      | ([$report.reactions[] | select(.on == $event.name)] | first // {}) as $reaction
      | "| \($i + 1) | \($event.name) | \($reaction.policy // "-") | \($reaction.trigger // "-") |"))
  + ["", "Planned from **\($planned.payload.source.value // "nothing")**: \($planned.payload.files.value // 0) files into \($planned.payload.shards.value // 0) shards, longest leg \($planned.payload.longest.value // 0) against a mean of \($planned.payload.mean.value // 0) (seconds, or bytes when planned from size)."]
| .[]
