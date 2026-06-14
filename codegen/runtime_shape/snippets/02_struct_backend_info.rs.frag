/// One row of the backend-map projection (i728) — which backend each repository
/// resolved to, without hydrating it. `Runtime::dump_backend_map` builds the Vec ;
/// the Phase-A enforcement gate diffs it before/after a change and treats any
/// unexpected backend flip as an automatic stop.
#[derive(Debug, Clone)]
pub struct BackendInfo {
    pub repo_key: String,
    pub kind: BackendKind,
    pub heki_path: Option<String>,
}
