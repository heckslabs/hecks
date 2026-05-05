/// One declared view (i254). Mirrors
/// `Hecks::BluebookModel::Structure::View`. Different portals read the
/// same aggregate through different views ; the view declaration is the
/// single source of truth for "which attributes does this role see".
///
/// `show_all = true` projects every aggregate attribute, then appends
/// `fields` as extras (customer view typically lists the explicit subset
/// with `show_all = false` ; admin view typically uses `show_all = true`
/// plus a few internal fields). `show_all = false` projects only the
/// explicit `fields` list.
