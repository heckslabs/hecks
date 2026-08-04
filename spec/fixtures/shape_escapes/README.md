Every file here is a bluebook whose storage-shape projection once came
out wrong — captured automatically by shape fuzzing and replayed, first,
on every run. Never delete one because it is inconvenient; it earned its
place by escaping.

Pruning is permitted, on the record: when several escapes share one
root cause that has been fixed, keep a representative and delete the
near-duplicates — in a commit whose message names the root cause they
shared. A slow pile of passing near-duplicates teaches nothing; a
pruned corpus with named causes is the history of where the projection
actually went wrong.
