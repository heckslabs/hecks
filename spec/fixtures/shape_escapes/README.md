Every file here is a bluebook on which the two runtimes' storage-shape
projections once disagreed — captured automatically by bin/fuzz_shapes
and replayed, first, on every run. Never delete one because it is
inconvenient; it earned its place by escaping.

Pruning is permitted, on the record: when several escapes share one
root cause that has been fixed, keep a representative and delete the
near-duplicates — in a commit whose message names the root cause they
shared. A slow pile of passing near-duplicates teaches nothing; a
pruned corpus with named causes is the history of where the two
implementations actually diverged.
