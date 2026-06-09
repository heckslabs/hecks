#[derive(Debug, Clone)]
pub struct CommandResult {
    pub aggregate_id: String,
    pub aggregate_type: String,
    pub event: Option<Event>,
}

/// Resolution of a dispatch address — i111-J.
///
/// `Aggregate(agg_idx, cmd_idx)` — command lives directly on the
/// aggregate's commands list.
///
/// `Entity(agg_idx, ent_idx, cmd_idx)` — command lives inside an
/// entity declared inside the aggregate's `entity "Foo" do … end`
/// block. Dispatch still operates on the parent aggregate's record
/// (entities are reached only through the root in DDD), but uses the
/// entity's command — its mutations, givens, lifecycle.
#[derive(Debug, Clone, Copy)]
enum Resolution {
    Aggregate(usize, usize),
    Entity(usize, usize, usize),
}

impl Resolution {
    fn agg_idx(&self) -> usize {
        match self {
            Resolution::Aggregate(a, _) => *a,
            Resolution::Entity(a, _, _) => *a,
        }
    }
}

/// Borrow the resolved command from the runtime's IR.
fn cmd_for<'a>(rt: &'a Runtime, res: Resolution) -> &'a Command {
    match res {
        Resolution::Aggregate(a, c) => &rt.domain.aggregates[a].commands[c],
        Resolution::Entity(a, e, c) => &rt.domain.aggregates[a].entities[e].commands[c],
    }
}

/// Borrow the lifecycle that gates the resolved command : the entity's
/// own lifecycle when present, otherwise the parent aggregate's.
fn lifecycle_for<'a>(rt: &'a Runtime, res: Resolution) -> Option<&'a Lifecycle> {
    match res {
        Resolution::Aggregate(a, _) => rt.domain.aggregates[a].lifecycle.as_ref(),
        Resolution::Entity(a, e, _) => rt.domain.aggregates[a].entities[e]
            .lifecycle
            .as_ref()
            .or(rt.domain.aggregates[a].lifecycle.as_ref()),
    }
}


/// A parsed cross-aggregate POINT-gate reference : `Aggregate(id_expr).field`.
/// Produced by `extract_xref_terms` from a `given` expression so the dispatch
/// layer can resolve one named sibling's field BEFORE the pipeline borrows the
/// repository `&mut`. The aggregate-consistency boundary holds : the command
/// still writes exactly ONE aggregate ; this is a READ at the gate (the port),
/// never a cross-aggregate write.
struct XrefTerm {
    aggregate: String,
    id_expr: String,
    field: String,
    full: String,
}

/// Extract every `Aggregate(id_expr).field` term from a `given` expression.
/// `Aggregate` is an UpperCamelCase identifier immediately followed by `(` ;
/// `id_expr` is the bare token inside the parens (a self field or inbound
/// attr) ; `field` is the single dotted suffix. Chained suffixes (`.a.b`) and
/// nested parens are not recognised — Slice-1 point gates read one field off
/// one named sibling.
fn extract_xref_terms(expr: &str) -> Vec<XrefTerm> {
    let bytes = expr.as_bytes();
    let mut terms = Vec::new();
    let mut i = 0;
    while i < bytes.len() {
        if !(bytes[i] as char).is_ascii_uppercase() {
            i += 1;
            continue;
        }
        let start = i;
        while i < bytes.len() && (bytes[i] as char).is_ascii_alphanumeric() {
            i += 1;
        }
        if i >= bytes.len() || bytes[i] != b'(' {
            continue;
        }
        let aggregate = expr[start..i].to_string();
        i += 1;
        let id_start = i;
        while i < bytes.len() && bytes[i] != b')' {
            i += 1;
        }
        if i >= bytes.len() {
            break;
        }
        let id_expr = expr[id_start..i].trim().to_string();
        i += 1;
        if i >= bytes.len() || bytes[i] != b'.' {
            continue;
        }
        i += 1;
        let field_start = i;
        while i < bytes.len()
            && ((bytes[i] as char).is_ascii_alphanumeric() || bytes[i] == b'_')
        {
            i += 1;
        }
        let field = expr[field_start..i].to_string();
        if !id_expr.is_empty() && !field.is_empty() {
            let full = expr[start..i].to_string();
            terms.push(XrefTerm { aggregate, id_expr, field, full });
        }
    }
    terms
}

fn resolve_cross_aggregate_gates(
    rt: &Runtime,
    cmd: &Command,
    self_state: Option<&AggregateState>,
    attrs: &mut HashMap<String, Value>,
) {
    for given in &cmd.givens {
        for term in extract_xref_terms(&given.expression) {
            if attrs.contains_key(&term.full) {
                continue;
            }
            // as a `Value::List` under the literal term. The interpreters
            // `.unresolved.empty?` then passes only when every dependency is
            // Uniqueness-gate : `Agg(field).active_peers` — the reserved `active_peers`
            // projection scans `Agg` for records that share the self's `id_expr` field
            // value AND are already in the "active" state, injecting their ids as a
            // `Value::List`. The interpreter's `.active_peers.empty?` then passes only
            // when no peer is active — enforcing one-active-per-group (Sprint.Activate's
            // `given { Sprint(project).active_peers.empty? }` : one active sprint per
            // project). The self excludes itself naturally : the given runs BEFORE the
            // planned->active transition, so the self is not yet active.
            if term.field == "active_peers" {
                let key_val = match attrs.get(&term.id_expr) {
                    Some(v) => v.to_string(),
                    None => match self_state {
                        Some(s) => s.get(&term.id_expr).to_string(),
                        None => String::new(),
                    },
                };
                let peers: Vec<Value> = rt
                    .all_qualified(None, &term.aggregate)
                    .into_iter()
                    .filter(|r| r.get(&term.id_expr).to_string() == key_val
                        && r.get("state").to_string() == "active")
                    .map(|r| Value::Str(r.id.clone()))
                    .collect();
                attrs.insert(term.full.clone(), Value::List(peers));
                continue;
            }
            let sibling_id = match attrs.get(&term.id_expr) {
                Some(v) => v.to_string(),
                None => match self_state {
                    Some(s) => s.get(&term.id_expr).to_string(),
                    None => String::new(),
                },
            };
            if sibling_id.is_empty() {
                continue;
            }
            if let Some(sibling) = rt.find(&term.aggregate, &sibling_id) {
                let val = sibling.get(&term.field).clone();
                attrs.insert(term.full.clone(), val);
            }
        }
    }
}
