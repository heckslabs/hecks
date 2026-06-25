/// Extract the `schema: { k: Type, ... }` kwarg from an `aggregate`
/// line. Returns None when the kwarg is absent. Single-line only
/// (v1 constraint); a multi-line `{ ... }` spanning several source
/// lines parses as absent.
///
/// Parse shape:
///   aggregate "X", schema: { ext: String } do
///                  ^^^^^^^^ ^^^^^^^^^^^^^
///                  |        |
///                  |        +-- inside {...}: top-level-comma-split
///                  |            pairs of `k: Type`, where Type is a
///                  |            verbatim token (may contain parens
///                  |            and commas — `list_of(String)` — so
///                  |            we reuse split_top_level_commas to
///                  |            respect nested brackets/parens).
///                  +-- we scan from after the first top-level comma
///                      on the aggregate line (the one separating the
///                      positional name from kwargs).
