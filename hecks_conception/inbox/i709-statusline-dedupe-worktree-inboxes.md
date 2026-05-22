# i709 — statusline counts the global inbox once per git worktree

The inbox-channel autoload (i528) renders the global inbox (crystal ball 🔮,
no abbrev) once per discovered `.channel.md`. A git worktree is a FULL checkout
that carries `hecks_conception/inbox/.channel.md`, so N live worktrees render the
crystal ball N times with an identical count. Tonight's agent swarm (5 concurrent
hecks checkouts — main + warmstore + forward + serve + fibroblast) surfaced it as
`🔮 391` repeated five times.

Not harmful — self-heals as worktrees are removed — but noisy during multi-worktree
swarms, which will be the norm once the fibroblast/sidequest fleet runs.

Fix : dedupe inbox channels by canonical inbox identity, not checkout path.
Options : resolve each channel to its git common-dir (worktrees share one) and
coalesce ; or skip non-primary worktrees ; or simply collapse channels with an
identical (realpath-of-inbox, icon, count) tuple so the global inbox renders
once regardless of how many worktrees exist. Belongs with the i528 channel-
autoload code.
