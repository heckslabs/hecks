/// One declared block grammar (i218). Mirrors
/// `Hecks::BluebookModel::Behavior::BlockGrammar`.
///
/// `blocks` is an ordered Vec of `(keyword, parser_kind)` pairs ; the
/// parser walks them in declaration order, claiming a line for the
/// first keyword whose prefix matches. Authors can shadow a parent
/// keyword by listing a more-specific keyword first.
