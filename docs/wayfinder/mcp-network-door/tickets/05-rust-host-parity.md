---
type: grilling
status: open
blocked_by: [04-composing-with-governance]
claimed_by:
---

# Rust host parity

## Question

The Rust host's invoke path takes `role` from the request body (`rust/host/src/server.rs`). A
separate change now stops a body from a non-loopback peer being read as the internal dispatch
protocol at all, which closes the public-caller case but leaves the same-host sidecar case
self-asserted. Decide whether the network door's token check also covers the host's internal
protocol (so a sidecar presents a principal too), whether the Ruby and Rust runtimes verify tokens
with one shared rule held byte-identical in CI like the other cross-runtime rules, and what the
Rust host does with a token it cannot verify.

## Answer
