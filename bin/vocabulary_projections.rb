# WHICH RUST ENUM EACH CLOSED SET BECOMES. The Rust name is Rust's business —
# the language calls the where-clause set `QueryComparator` because that is what
# a domain expert would call it, and Rust calls it `WhereOp` because that is what
# its parser reads. Two names for one set, said once, here.
#
# READ BY TWO GENERATORS, which is why it is a file rather than a constant in
# one of them. `bin/ir_vocabulary` projects the sets themselves into enum
# declarations ; `bin/ir_structs` turns an attribute's `admits:` into the enum
# name when it types a field. A second copy of this table in the second reader
# would be exactly the drift both scripts exist to remove.
PROJECTIONS = {
  "MutationOp"      => "MutationOp",
  "QueryComparator" => "WhereOp"
}.freeze
