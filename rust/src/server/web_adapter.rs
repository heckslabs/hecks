//! :web adapter primitive — bluebook-driven HTTP route registration
//!
//! Walks every loaded hecksagon for `adapter :web` declarations and
//! builds a route registry. Each :web adapter declares :
//!
//!   adapter :web,
//!     get: "/path/with/:params",
//!     template_path: "..."          ← static template file (text/html)
//!   adapter :web,
//!     get: "/path/with/:params",
//!     serializer: :name             ← named runtime serializer (JSON)
//!
//! The dev server (`server::multi`) consults this registry on each
//! request before falling through to its hardcoded routes. When a
//! request matches, params bind from the path segments and the
//! configured response shape is rendered.
//!
//! Closes the framework gap that forced the LivingDiagram surface to
//! live in pure Rust : the bluebook (runtime/living_diagram/
//! living_diagram.bluebook) declares the domain ; the hecksagon
//! (runtime/living_diagram/living_diagram.hecksagon) declares the
//! routes ; this adapter primitive is the runtime that makes the
//! declaration dispatch.
//!
//! Usage:
//!   let registry = WebRegistry::scan(&hecksagons);
//!   if let Some(resp) = registry.resolve("GET", path) { … }
//!
//! [antibody-exempt: rust/src/server/web_adapter.rs — i527 :web
//!  adapter primitive. Brand-new framework adapter kind that lets
//!  hecksagons declare HTTP routes. Same retirement contract as
//!  llm_dispatcher / compute_dispatcher : kernel-floor primitive a
//!  bluebook capability dispatches into. The hecksagon is the spec
//!  ; this file is the runtime.]

use crate::hecksagon_ir::{Hecksagon, IoAdapter};
use std::collections::HashMap;
use std::path::PathBuf;

/// One registered :web adapter — the resolved declaration from a
/// hecksagon, ready for route matching.
#[derive(Debug, Clone)]
pub struct WebRoute {
    /// HTTP method, uppercase. Today only "GET" is wired ; POST will
    /// land when the dispatch-from-form route moves into the
    /// hecksagon (currently goes through /domains/:name/dispatch).
    pub method: String,
    /// Raw path pattern from the hecksagon, e.g.
    /// `"/diagram/:domain_name/graph.json"`. Used for matching ;
    /// the captured `:param` segments are extracted by `match_path`.
    pub pattern: String,
    /// Pre-split pattern segments — same as `pattern.split('/')` but
    /// computed once. Empty leading element (from the leading slash)
    /// is preserved so segment-count matching is straightforward.
    pub segments: Vec<String>,
    /// Path to a static template file the server reads + substitutes
    /// `{{param}}` against the matched path params. None when
    /// `serializer` is set.
    pub template_path: Option<PathBuf>,
    /// Named runtime serializer — for now only `graph_projection` is
    /// recognised. The server emits the corresponding JSON shape.
    pub serializer: Option<String>,
    /// Content-Type header for the response. Defaults to text/html
    /// when template_path is set, application/json when serializer is.
    pub content_type: String,
    /// Hecksagon this declaration came from — useful for diagnostics.
    pub source_hecksagon: String,
    /// Options the adapter declared that aren't recognised as
    /// route control fields ; supplied as default template params.
    /// Lets a hecksagon hard-bind a route with constants like
    /// `domain_name: "_all"` for the universe view.
    pub defaults: HashMap<String, String>,
}

/// The route registry. Built once at server boot, consulted per request.
#[derive(Debug, Default)]
pub struct WebRegistry {
    routes: Vec<WebRoute>,
}

impl WebRegistry {
    /// Walk every hecksagon's io_adapters, collect every kind=="web"
    /// entry, build WebRoute records.
    pub fn scan(hecksagons: &HashMap<String, Hecksagon>, repo_root: &std::path::Path) -> Self {
        let mut routes = Vec::new();
        for (hex_name, hex) in hecksagons {
            for adapter in &hex.io_adapters {
                if adapter.kind != "web" { continue; }
                if let Some(route) = build_route(adapter, hex_name, repo_root) {
                    routes.push(route);
                }
            }
        }
        WebRegistry { routes }
    }

    /// Try to resolve a request to a registered route. On match,
    /// returns the route plus the captured path params.
    pub fn resolve(&self, method: &str, path: &str)
        -> Option<(&WebRoute, HashMap<String, String>)>
    {
        self.resolve_all(method, path).into_iter().next()
    }

    /// Return every route that matches, in registration order. The
    /// caller (`handle_multi`) tries them in turn so a literal route
    /// that matches alongside a parametric route can claim the
    /// request when its serializer succeeds and the parametric one
    /// can't fulfil it.
    pub fn resolve_all(&self, method: &str, path: &str)
        -> Vec<(&WebRoute, HashMap<String, String>)>
    {
        let req_segs: Vec<&str> = path.split('/').collect();
        let mut out = Vec::new();
        for route in &self.routes {
            if !method.eq_ignore_ascii_case(&route.method) { continue; }
            if let Some(params) = match_path(&route.segments, &req_segs) {
                out.push((route, params));
            }
        }
        // Prefer routes with no `:params` first (literal > parametric).
        // A route's specificity is the count of NON-`:`-prefixed
        // segments ; higher specificity wins.
        out.sort_by_key(|(route, _)| {
            let literals = route.segments.iter()
                .filter(|s| !s.starts_with(':'))
                .count();
            std::cmp::Reverse(literals)
        });
        out
    }

    pub fn len(&self) -> usize { self.routes.len() }
    pub fn is_empty(&self) -> bool { self.routes.is_empty() }
    pub fn routes(&self) -> &[WebRoute] { &self.routes }
}

/// Translate one IoAdapter (kind=="web") into a WebRoute. Returns
/// None when the declaration is malformed (missing route + missing
/// template/serializer pair).
fn build_route(adapter: &IoAdapter, source: &str, repo_root: &std::path::Path)
    -> Option<WebRoute>
{
    let mut method = "GET".to_string();
    let mut pattern = String::new();
    let mut template_path: Option<PathBuf> = None;
    let mut serializer: Option<String> = None;
    let mut content_type: Option<String> = None;
    let mut defaults: HashMap<String, String> = HashMap::new();

    for (k, v) in &adapter.options {
        // The hecksagon parser preserves raw token values, including
        // surrounding quote characters and leading symbol-colons.
        // Strip both so segment-by-segment matching works against
        // the actual request paths.
        let v = strip_quotes_and_symbol(v);
        match k.as_str() {
            "get"          => { method = "GET".into();   pattern = v; }
            "post"         => { method = "POST".into();  pattern = v; }
            "put"          => { method = "PUT".into();   pattern = v; }
            "delete"       => { method = "DELETE".into(); pattern = v; }
            "template_path" => template_path = Some(repo_root.join(&v)),
            "serializer"    => serializer = Some(v),
            "content_type"  => content_type = Some(v),
            "name" => {} // Adapter name — purely diagnostic, ignored here.
            other => { defaults.insert(other.to_string(), v); }
        }
    }

    if pattern.is_empty() { return None; }
    if template_path.is_none() && serializer.is_none() { return None; }

    let segments: Vec<String> = pattern.split('/').map(String::from).collect();
    let content_type = content_type.unwrap_or_else(|| {
        if template_path.is_some() { "text/html".into() } else { "application/json".into() }
    });

    Some(WebRoute {
        method,
        pattern,
        segments,
        template_path,
        serializer,
        content_type,
        source_hecksagon: source.to_string(),
        defaults,
    })
}

/// Strip a single layer of surrounding quote characters AND a
/// leading `:` (Ruby symbol marker). The hecksagon parser preserves
/// these in the raw option values ; the runtime needs the bare
/// content. `"\"/diagram/:x\""` → `"/diagram/:x"`. `":graph_projection"`
/// → `"graph_projection"`. `"text/html"` (when authored as a string
/// without quotes in the parser's eyes) is left as-is.
fn strip_quotes_and_symbol(v: &str) -> String {
    let trimmed = v.trim();
    let unquoted = if (trimmed.starts_with('"') && trimmed.ends_with('"') && trimmed.len() >= 2)
        || (trimmed.starts_with('\'') && trimmed.ends_with('\'') && trimmed.len() >= 2)
    {
        &trimmed[1..trimmed.len() - 1]
    } else {
        trimmed
    };
    unquoted.strip_prefix(':').unwrap_or(unquoted).to_string()
}

/// Match a request's path segments against a route pattern's segments.
/// Returns Some(params) on match, None otherwise. Pattern segments
/// starting with `:` capture the corresponding request segment.
fn match_path(pattern_segs: &[String], req_segs: &[&str]) -> Option<HashMap<String, String>> {
    if pattern_segs.len() != req_segs.len() { return None; }
    let mut params = HashMap::new();
    for (p, r) in pattern_segs.iter().zip(req_segs.iter()) {
        if let Some(name) = p.strip_prefix(':') {
            params.insert(name.to_string(), (*r).to_string());
        } else if p != r {
            return None;
        }
    }
    Some(params)
}

/// Render a route's response. Templates : read the file, replace
/// `{{param}}` placeholders with the matched params, return the
/// substituted text. Serializers : invoke the named projection.
pub fn render(
    route: &WebRoute,
    params: &HashMap<String, String>,
    runtimes: &std::collections::HashMap<String, std::cell::RefCell<crate::runtime::Runtime>>,
) -> Option<(String, String)> {
    // Merge declared defaults under matched URL params : URL wins
    // when both name the same key, but a route with no path-params
    // (e.g. /diagram) can hard-bind values like domain_name: "_all".
    let mut merged: HashMap<String, String> = route.defaults.clone();
    for (k, v) in params { merged.insert(k.clone(), v.clone()); }

    if let Some(ref template_path) = route.template_path {
        let text = std::fs::read_to_string(template_path).ok()?;
        let mut out = text;
        for (k, v) in &merged {
            out = out.replace(&format!("{{{{{}}}}}", k), v);
        }
        return Some((route.content_type.clone(), out));
    }
    if let Some(ref serializer) = route.serializer {
        match serializer.as_str() {
            "graph_projection" => {
                let domain_name = merged.get("domain_name")?;
                let rt = runtimes.get(domain_name)?;
                let body = crate::server::html_diagram::graph_json(&rt.borrow());
                return Some((route.content_type.clone(), body));
            }
            "all_domains_graph_projection" => {
                let body = crate::server::html_diagram::all_domains_graph_json(runtimes);
                return Some((route.content_type.clone(), body));
            }
            _ => return None,
        }
    }
    None
}
