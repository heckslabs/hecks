//! Living Diagram — render the bluebook as a clickable, observable graph
//!
//! Walks the runtime's Domain IR and emits one HTML page that draws
//! every aggregate / command / event / policy as a node, with edges
//! for emits / triggers_on / cascades / references. Cytoscape.js
//! (CDN) handles layout + interaction. Click a command node to open
//! a dispatch form ; submit hits the existing /domains/:name/dispatch
//! endpoint ; the response feeds an event panel.
//!
//! This is the dev-server surface backing
//! `runtime/living_diagram/living_diagram.bluebook` — the bluebook
//! is the domain spec, this module is the I/O wiring (a future
//! `runtime/living_diagram/living_diagram.hecksagon` :web adapter
//! would dispatch the diagram render through the runtime instead of
//! a hard-coded function).
//!
//! Usage:
//!   let html = html_diagram::generate(name, rt);
//!
//! [antibody-exempt: rust/src/server/html_diagram.rs — i527 LivingDiagram
//!  dev-server surface. Kernel-surface HTTP + HTML glue ; the bluebook
//!  domain (runtime/living_diagram/living_diagram.bluebook) is the
//!  spec. Retires when the dev server is itself dispatched from a
//!  living_diagram.hecksagon :web adapter.]

use crate::runtime::Runtime;
use crate::json_helpers::json_str;
use std::cell::RefCell;

/// Render the Living Diagram page for one domain. The page embeds
/// the domain's full graph as JSON, then hands off to Cytoscape for
/// layout + rendering. Edge animation on cascade is wired via SSE
/// (future) ; today the page is structural.
pub fn generate(domain_name: &str, rt: &RefCell<Runtime>) -> String {
    let rt = rt.borrow();
    let graph_json = build_graph_json(&rt);
    let domain_label = json_str(domain_name);

    format!(
        r#"<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>{name} — Living Diagram</title>
  <script src="https://cdn.tailwindcss.com"></script>
  <script src="https://unpkg.com/cytoscape@3.30.4/dist/cytoscape.min.js"></script>
  <style>
    body {{ margin: 0; background: #0a0a0a; color: #ddd; font-family: -apple-system, system-ui, sans-serif; }}
    #cy {{ width: 100vw; height: calc(100vh - 56px); }}
    header {{ height: 56px; padding: 0 1.5rem; background: #111; border-bottom: 1px solid #222; display: flex; align-items: center; justify-content: space-between; }}
    h1 {{ font-size: 1.1rem; font-weight: 600; color: #ffe400; }}
    .pill {{ display: inline-block; padding: 2px 8px; border-radius: 999px; font-size: 0.75rem; margin-left: 0.5rem; }}
    .pill-aggregate {{ background: #ffe400; color: #111; }}
    .pill-command   {{ background: #5b9eff; color: #fff; }}
    .pill-event     {{ background: #b275ff; color: #fff; }}
    .pill-policy    {{ background: #ff7d5b; color: #fff; }}
    #panel {{ position: fixed; right: 1rem; top: 72px; width: 360px; max-height: calc(100vh - 96px); overflow-y: auto; background: #1a1a1a; border: 1px solid #2a2a2a; border-radius: 12px; padding: 1rem; display: none; }}
    #panel.open {{ display: block; }}
    #panel h2 {{ font-size: 1rem; font-weight: 600; color: #ffe400; margin-bottom: 0.5rem; }}
    #panel .desc {{ font-size: 0.85rem; color: #999; margin-bottom: 1rem; }}
    #panel input, #panel button, #panel textarea {{ width: 100%; padding: 6px 10px; margin-bottom: 8px; background: #222; border: 1px solid #333; color: #eee; border-radius: 6px; font-size: 0.85rem; }}
    #panel button {{ background: #ffe400; color: #111; font-weight: 600; cursor: pointer; }}
    #panel button:hover {{ background: #ffd200; }}
    #panel .label {{ font-size: 0.75rem; color: #888; text-transform: uppercase; letter-spacing: 0.05em; margin-bottom: 2px; }}
    #panel .result {{ margin-top: 1rem; padding: 8px 10px; border-radius: 6px; font-size: 0.85rem; }}
    #panel .result.ok    {{ background: rgba(34, 197, 94, 0.1);  color: #5fde8a; }}
    #panel .result.error {{ background: rgba(239, 68, 68, 0.15); color: #ff8a8a; }}
    #legend {{ position: fixed; left: 1rem; bottom: 1rem; background: rgba(20,20,20,0.95); border: 1px solid #2a2a2a; border-radius: 8px; padding: 8px 12px; font-size: 0.75rem; }}
    #legend span {{ margin-right: 0.75rem; }}
    .close {{ float: right; background: transparent; border: none; color: #888; font-size: 1.25rem; cursor: pointer; padding: 0; width: auto; margin: 0; }}
  </style>
</head>
<body>
  <header>
    <h1>📊 {name} — Living Diagram</h1>
    <a href="/domains/{name}" class="text-sm text-gray-400 hover:text-white">← Walking Skeleton</a>
  </header>
  <div id="cy"></div>

  <div id="legend">
    <span>● <em class="pill-aggregate" style="background:#ffe400;color:#111;padding:1px 6px;border-radius:8px;">aggregate</em></span>
    <span>● <em class="pill-command" style="background:#5b9eff;color:#fff;padding:1px 6px;border-radius:8px;">command</em></span>
    <span>● <em class="pill-event" style="background:#b275ff;color:#fff;padding:1px 6px;border-radius:8px;">event</em></span>
    <span>● <em class="pill-policy" style="background:#ff7d5b;color:#fff;padding:1px 6px;border-radius:8px;">policy</em></span>
  </div>

  <div id="panel">
    <button class="close" onclick="closePanel()">×</button>
    <div id="panel-content"></div>
  </div>

  <script>
    const GRAPH = {graph};
    const DOMAIN = {domain};

    const cy = cytoscape({{
      container: document.getElementById('cy'),
      elements: GRAPH,
      style: [
        {{ selector: 'node', style: {{
          'label': 'data(label)',
          'text-valign': 'center',
          'text-halign': 'center',
          'font-size': 11,
          'color': '#fff',
          'text-outline-width': 2,
          'text-outline-color': '#0a0a0a',
          'border-width': 2,
          'border-color': '#0a0a0a',
        }} }},
        {{ selector: 'node[kind="aggregate"]', style: {{
          'background-color': '#ffe400',
          'color': '#111',
          'text-outline-color': '#ffe400',
          'shape': 'round-rectangle',
          'width': 'label',
          'height': 36,
          'padding': 12,
          'font-weight': 'bold',
          'font-size': 13,
        }} }},
        {{ selector: 'node[kind="command"]', style: {{
          'background-color': '#5b9eff',
          'shape': 'ellipse',
          'width': 'label',
          'height': 28,
          'padding': 8,
        }} }},
        {{ selector: 'node[kind="event"]', style: {{
          'background-color': '#b275ff',
          'shape': 'diamond',
          'width': 32,
          'height': 32,
        }} }},
        {{ selector: 'node[kind="policy"]', style: {{
          'background-color': '#ff7d5b',
          'shape': 'tag',
          'width': 'label',
          'height': 24,
          'padding': 6,
        }} }},
        {{ selector: 'edge', style: {{
          'width': 2,
          'line-color': '#444',
          'target-arrow-color': '#444',
          'target-arrow-shape': 'triangle',
          'curve-style': 'bezier',
        }} }},
        {{ selector: 'edge[kind="emits"]', style: {{
          'line-color': '#b275ff',
          'target-arrow-color': '#b275ff',
        }} }},
        {{ selector: 'edge[kind="triggers"]', style: {{
          'line-color': '#ff7d5b',
          'target-arrow-color': '#ff7d5b',
          'line-style': 'dashed',
        }} }},
        {{ selector: 'edge[kind="references"]', style: {{
          'line-color': '#666',
          'target-arrow-color': '#666',
          'line-style': 'dotted',
        }} }},
        {{ selector: 'edge[kind="contains"]', style: {{
          'line-color': '#333',
          'target-arrow-shape': 'none',
          'opacity': 0.5,
        }} }},
        {{ selector: '.firing', style: {{
          'line-color': '#5fde8a',
          'target-arrow-color': '#5fde8a',
          'width': 4,
        }} }},
      ],
      layout: {{
        name: 'cose',
        idealEdgeLength: 90,
        nodeRepulsion: 6000,
        animate: true,
        randomize: false,
      }},
    }});

    const panel = document.getElementById('panel');
    const content = document.getElementById('panel-content');
    function closePanel() {{ panel.classList.remove('open'); }}

    cy.on('tap', 'node', evt => {{
      const node = evt.target;
      const data = node.data();
      if (data.kind === 'command') showCommandForm(data);
      else if (data.kind === 'aggregate') showAggregate(data);
      else if (data.kind === 'event') showEvent(data);
      else if (data.kind === 'policy') showPolicy(data);
    }});

    function showCommandForm(data) {{
      const fields = (data.attrs || []).map(a => `
        <div>
          <div class="label">${{a.name}} <span style="color:#666">${{a.type}}</span></div>
          <input name="${{a.name}}" placeholder="${{a.type}}">
        </div>
      `).join('');
      content.innerHTML = `
        <h2>${{data.aggregate}}.${{data.command}}</h2>
        <div class="desc">${{data.description || 'Dispatch this command.'}}</div>
        <form id="cmd-form" onsubmit="dispatch(event, '${{data.command}}', '${{data.id}}')">
          ${{fields}}
          <button type="submit">Dispatch ▶</button>
        </form>
        <div id="cmd-result"></div>
      `;
      panel.classList.add('open');
    }}

    function showAggregate(data) {{
      content.innerHTML = `<h2>${{data.label}}</h2><div class="desc">Aggregate. ${{data.commandCount || 0}} commands.</div>`;
      panel.classList.add('open');
    }}
    function showEvent(data) {{
      content.innerHTML = `<h2>${{data.label}}</h2><div class="desc">Event emitted by ${{data.emittedBy || 'a command'}}.</div>`;
      panel.classList.add('open');
    }}
    function showPolicy(data) {{
      content.innerHTML = `<h2>${{data.label}}</h2><div class="desc">Policy. On <em>${{data.on}}</em> trigger <em>${{data.trigger}}</em>.</div>`;
      panel.classList.add('open');
    }}

    function dispatch(e, cmd, nodeId) {{
      e.preventDefault();
      const form = e.target;
      const data = {{}};
      new FormData(form).forEach((v, k) => {{ if (v) data[k] = v; }});
      const result = document.getElementById('cmd-result');
      result.className = '';
      result.textContent = 'Dispatching…';
      fetch(`/domains/${{DOMAIN}}/dispatch`, {{
        method: 'POST',
        headers: {{ 'Content-Type': 'application/json' }},
        body: JSON.stringify({{ command: cmd, attrs: data }}),
      }})
      .then(r => r.json())
      .then(r => {{
        if (r.ok) {{
          result.className = 'result ok';
          result.textContent = `✓ ${{r.event || 'success'}} on ${{r.aggregate_type}}#${{r.aggregate_id}}`;
          if (r.event) animateEdgeFromEvent(r.event, cmd);
        }} else {{
          result.className = 'result error';
          result.textContent = `✗ ${{r.error}}`;
        }}
      }})
      .catch(err => {{
        result.className = 'result error';
        result.textContent = `✗ ${{err.message}}`;
      }});
    }}

    function animateEdgeFromEvent(eventName, cmdName) {{
      // Find the emits edge from this command to the event ; light it up briefly.
      const edges = cy.edges(`[kind="emits"][source="cmd:${{cmdName}}"][target="evt:${{eventName}}"]`);
      edges.addClass('firing');
      setTimeout(() => edges.removeClass('firing'), 1500);
    }}
  </script>
</body>
</html>"#,
        name = domain_name,
        domain = domain_label,
        graph = graph_json,
    )
}

/// Walk the Domain IR and emit a Cytoscape elements list as JSON.
/// Nodes: aggregates, commands (per aggregate), events (per emits),
/// policies. Edges: aggregate→command (contains), command→event
/// (emits), event→policy (on, the policy listens), policy→command
/// (triggers), aggregate→aggregate (references).
///
/// Public so the :web adapter primitive (`server::web_adapter::render`)
/// can serve this as the `graph_projection` serializer's body when a
/// hecksagon route declares `serializer: :graph_projection`.
pub fn graph_json(rt: &Runtime) -> String {
    build_graph_json(rt)
}

/// Universe view — every loaded domain in one Cytoscape elements
/// list. Each domain's nodes are namespaced (`<DomainName>::<id>`) so
/// otherwise-clashing aggregate names from sibling domains stay
/// distinct in the rendered graph. Cross-domain references — when
/// an aggregate names a target that lives in another loaded domain —
/// become dashed `cross_domain` edges so the universe's structural
/// joins read at a glance.
///
/// Used by the LivingDiagram hecksagon's `:all_domains_graph_projection`
/// serializer when the operator opens `/diagram` (no domain name).
pub fn all_domains_graph_json(
    runtimes: &std::collections::HashMap<String, std::cell::RefCell<Runtime>>,
) -> String {
    use std::collections::BTreeMap;

    // Index every aggregate name → its owning domain. Used to detect
    // when one domain's reference target lives in a sibling domain.
    let mut owner_of: BTreeMap<String, String> = BTreeMap::new();
    for (domain_name, rt_cell) in runtimes {
        let rt = rt_cell.borrow();
        for agg in &rt.domain.aggregates {
            owner_of.entry(agg.name.clone()).or_insert(domain_name.clone());
        }
    }

    let mut all_nodes: Vec<String> = Vec::new();
    let mut all_edges: Vec<String> = Vec::new();

    // Walk every runtime, emit its sub-graph with namespaced ids.
    let mut domain_names: Vec<&String> = runtimes.keys().collect();
    domain_names.sort();
    for domain_name in domain_names {
        let rt = runtimes.get(domain_name).unwrap().borrow();
        let sub = build_graph_json(&rt);
        // Re-namespace : prepend `<DomainName>::` to every id /
        // source / target inside this sub-graph, then merge.
        let renamed = renamespace_graph(&sub, domain_name);
        // Split into nodes and edges by checking for "source"
        // (edges) vs no source (nodes). The sub-graph is a JSON
        // array — re-emit via simple textual merge.
        all_nodes.push(renamed);
    }

    // Cross-domain edges : aggregate -> aggregate where the target
    // lives in a different domain. These are dashed and styled
    // distinctly from in-domain references.
    for (domain_name, rt_cell) in runtimes {
        let rt = rt_cell.borrow();
        for agg in &rt.domain.aggregates {
            for r in &agg.references {
                if let Some(target_owner) = owner_of.get(&r.target) {
                    if target_owner != domain_name {
                        all_edges.push(format!(
                            r#"{{"data":{{"source":"{}::agg:{}","target":"{}::agg:{}","kind":"cross_domain","alias":{}}}}}"#,
                            domain_name, agg.name,
                            target_owner, r.target,
                            json_str(&r.name)
                        ));
                    }
                }
            }
        }
    }

    // Merge : strip the `[` and `]` from each sub-array, glue.
    let bodies: Vec<String> = all_nodes.iter()
        .map(|s| s.trim_start_matches('[').trim_end_matches(']').to_string())
        .filter(|s| !s.is_empty())
        .collect();
    let nodes_blob = bodies.join(",");
    let cross_blob = all_edges.join(",");
    if cross_blob.is_empty() {
        format!("[{}]", nodes_blob)
    } else if nodes_blob.is_empty() {
        format!("[{}]", cross_blob)
    } else {
        format!("[{},{}]", nodes_blob, cross_blob)
    }
}

/// Take a graph JSON array (as produced by build_graph_json) and
/// prefix every node id / edge source / edge target with
/// `<domain>::`, plus stamp a `domain` field onto every node so the
/// browser can route aggregate clicks to the right solo diagram.
fn renamespace_graph(json: &str, domain_name: &str) -> String {
    let prefix = format!("{}::", domain_name);
    // Naive but effective : the only places the ids appear in our
    // output are as `"id":"<id>"`, `"source":"<id>"`, `"target":"<id>"`.
    // Replace those occurrences ; leave attribute strings alone.
    let mut out = json.replace(r#""id":""#, &format!(r#""id":"{}"#, prefix));
    out = out.replace(r#""source":""#, &format!(r#""source":"{}"#, prefix));
    out = out.replace(r#""target":""#, &format!(r#""target":"{}"#, prefix));
    // Stamp the domain on every node by appending after the kind.
    // We insert "domain":"<name>" after every kind:"X" in node data.
    let dn = json_str(domain_name);
    out = out.replace(
        r#""kind":"aggregate""#,
        &format!(r#""kind":"aggregate","domain":{}"#, dn),
    );
    out
}

/// Build a comprehensive Cytoscape elements list. Every IR concept
/// gets a node ; every relationship gets an edge.
///
///   nodes  : aggregate | command | event | policy | value_object |
///            entity | query | state | process_manager
///   edges  : contains  (aggregate → command | VO | entity | query | state)
///            emits     (command   → event)
///            triggers  (event     → policy ; policy → command)
///            references (aggregate → aggregate, with `as:` alias)
///            transitions (command → state, captured from lifecycle)
///            correlates (PM → event)
///            pm_drives  (PM → state, declared states the PM walks)
fn build_graph_json(rt: &Runtime) -> String {
    let mut nodes: Vec<String> = Vec::new();
    let mut edges: Vec<String> = Vec::new();
    let mut event_seen: std::collections::BTreeSet<String> =
        std::collections::BTreeSet::new();
    let mut state_seen: std::collections::BTreeSet<String> =
        std::collections::BTreeSet::new();

    // Local aggregate names — used to filter reference edges whose
    // target lives in another domain (those would render as edges
    // with no endpoint in the solo view, which Cytoscape rejects ;
    // the Universe view handles cross-domain via its own edge kind).
    let local_aggs: std::collections::BTreeSet<String> =
        rt.domain.aggregates.iter().map(|a| a.name.clone()).collect();

    for agg in &rt.domain.aggregates {
        let agg_id = format!("agg:{}", agg.name);
        let total_children = agg.commands.len() + agg.value_objects.len()
            + agg.entities.len() + agg.queries.len();
        nodes.push(format!(
            r#"{{"data":{{"id":{id},"label":{label},"kind":"aggregate","commandCount":{cn},"voCount":{vn},"entityCount":{en},"queryCount":{qn},"totalChildren":{tn}}}}}"#,
            id = json_str(&agg_id),
            label = json_str(&agg.name),
            cn = agg.commands.len(),
            vn = agg.value_objects.len(),
            en = agg.entities.len(),
            qn = agg.queries.len(),
            tn = total_children,
        ));

        // ── Value objects ─────────────────────────────────────────
        for vo in &agg.value_objects {
            let vo_id = format!("vo:{}.{}", agg.name, vo.name);
            let vo_attrs: Vec<String> = vo.attributes.iter().map(|a| format!(
                r#"{{"name":{},"type":{}}}"#, json_str(&a.name), json_str(&a.attr_type)
            )).collect();
            nodes.push(format!(
                r#"{{"data":{{"id":{id},"label":{label},"kind":"value_object","aggregate":{agg},"description":{desc},"attrs":[{attrs}]}}}}"#,
                id = json_str(&vo_id),
                label = json_str(&vo.name),
                agg = json_str(&agg.name),
                desc = json_str(vo.description.as_deref().unwrap_or("")),
                attrs = vo_attrs.join(","),
            ));
            edges.push(format!(
                r#"{{"data":{{"source":{},"target":{},"kind":"contains"}}}}"#,
                json_str(&agg_id), json_str(&vo_id)
            ));
        }

        // ── Entities (have identity, distinct from VOs) ──────────
        for ent in &agg.entities {
            let ent_id = format!("ent:{}.{}", agg.name, ent.name);
            let ent_attrs: Vec<String> = ent.attributes.iter().map(|a| format!(
                r#"{{"name":{},"type":{}}}"#, json_str(&a.name), json_str(&a.attr_type)
            )).collect();
            nodes.push(format!(
                r#"{{"data":{{"id":{id},"label":{label},"kind":"entity","aggregate":{agg},"description":{desc},"attrs":[{attrs}]}}}}"#,
                id = json_str(&ent_id),
                label = json_str(&ent.name),
                agg = json_str(&agg.name),
                desc = json_str(ent.description.as_deref().unwrap_or("")),
                attrs = ent_attrs.join(","),
            ));
            edges.push(format!(
                r#"{{"data":{{"source":{},"target":{},"kind":"contains"}}}}"#,
                json_str(&agg_id), json_str(&ent_id)
            ));
        }

        // ── Queries (read-side, distinct from commands) ──────────
        for q in &agg.queries {
            let q_id = format!("qry:{}.{}", agg.name, q.name);
            nodes.push(format!(
                r#"{{"data":{{"id":{id},"label":{label},"kind":"query","aggregate":{agg},"description":{desc}}}}}"#,
                id = json_str(&q_id),
                label = json_str(&q.name),
                agg = json_str(&agg.name),
                desc = json_str(q.description.as_deref().unwrap_or("")),
            ));
            edges.push(format!(
                r#"{{"data":{{"source":{},"target":{},"kind":"contains"}}}}"#,
                json_str(&agg_id), json_str(&q_id)
            ));
        }

        // ── Lifecycle states (one node per declared state) ───────
        if let Some(ref lc) = agg.lifecycle {
            // Collect every state name : default + every from/to
            let mut states: std::collections::BTreeSet<String> =
                std::collections::BTreeSet::new();
            states.insert(lc.default.clone());
            for t in &lc.transitions {
                states.insert(t.to_state.clone());
                if let Some(ref f) = t.from_state {
                    states.insert(f.clone());
                }
            }
            for s in &states {
                let st_id = format!("state:{}.{}", agg.name, s);
                if state_seen.insert(st_id.clone()) {
                    let is_default = s == &lc.default;
                    nodes.push(format!(
                        r#"{{"data":{{"id":{id},"label":{label},"kind":"state","aggregate":{agg},"isDefault":{def}}}}}"#,
                        id = json_str(&st_id),
                        label = json_str(s),
                        agg = json_str(&agg.name),
                        def = is_default,
                    ));
                    edges.push(format!(
                        r#"{{"data":{{"source":{},"target":{},"kind":"contains"}}}}"#,
                        json_str(&agg_id), json_str(&st_id)
                    ));
                }
            }
            // Transitions : command → to_state
            for t in &lc.transitions {
                let cmd_id = format!("cmd:{}", t.command);
                let to_id = format!("state:{}.{}", agg.name, t.to_state);
                edges.push(format!(
                    r#"{{"data":{{"source":{},"target":{},"kind":"transition","fromState":{}}}}}"#,
                    json_str(&cmd_id), json_str(&to_id),
                    json_str(t.from_state.as_deref().unwrap_or("*")),
                ));
            }
        }

        // ── Commands ─────────────────────────────────────────────
        for cmd in &agg.commands {
            let cmd_id = format!("cmd:{}", cmd.name);
            let attrs_json: Vec<String> = cmd.attributes.iter().map(|a| {
                format!(
                    r#"{{"name":{},"type":{},"list":{}}}"#,
                    json_str(&a.name), json_str(&a.attr_type), a.list
                )
            }).collect();
            // References on the command surface — these become
            // dropdowns in the form (browser fetches /domains/X/aggregates/Y).
            let refs_json: Vec<String> = cmd.references.iter().map(|r| {
                format!(
                    r#"{{"name":{},"target":{}}}"#,
                    json_str(&r.name), json_str(&r.target)
                )
            }).collect();
            // Mutations — what fields this command writes.
            let muts_json: Vec<String> = cmd.mutations.iter().map(|m| {
                format!(
                    r#"{{"field":{},"op":"{:?}"}}"#,
                    json_str(&m.field), m.operation
                )
            }).collect();
            // Givens — preconditions worth showing in the panel.
            let givens_json: Vec<String> = cmd.givens.iter().map(|g| {
                format!(
                    r#"{{"message":{},"expression":{}}}"#,
                    json_str(g.message.as_deref().unwrap_or("")),
                    json_str(&g.expression)
                )
            }).collect();
            nodes.push(format!(
                r#"{{"data":{{"id":{id},"label":{label},"kind":"command","aggregate":{agg},"command":{cmd},"role":{role},"description":{desc},"attrs":[{attrs}],"references":[{refs}],"mutations":[{muts}],"givens":[{givens}]}}}}"#,
                id = json_str(&cmd_id),
                label = json_str(&cmd.name),
                agg = json_str(&agg.name),
                cmd = json_str(&cmd.name),
                role = json_str(cmd.role.as_deref().unwrap_or("")),
                desc = json_str(cmd.description.as_deref().unwrap_or("")),
                attrs = attrs_json.join(","),
                refs = refs_json.join(","),
                muts = muts_json.join(","),
                givens = givens_json.join(","),
            ));
            edges.push(format!(
                r#"{{"data":{{"source":{},"target":{},"kind":"contains"}}}}"#,
                json_str(&agg_id), json_str(&cmd_id)
            ));

            if let Some(ref event) = cmd.emits {
                let evt_id = format!("evt:{}", event);
                if event_seen.insert(event.clone()) {
                    nodes.push(format!(
                        r#"{{"data":{{"id":{},"label":{},"kind":"event","emittedBy":{}}}}}"#,
                        json_str(&evt_id), json_str(event), json_str(&cmd.name)
                    ));
                }
                edges.push(format!(
                    r#"{{"data":{{"source":{},"target":{},"kind":"emits"}}}}"#,
                    json_str(&cmd_id), json_str(&evt_id)
                ));
            }
        }

        // ── Aggregate-level references (with `as:` aliases) ──────
        // Solo view : only emit edges whose target is a LOCAL
        // aggregate. Cross-domain references would dangle (the
        // target node doesn't exist in this solo graph) and break
        // Cytoscape's render. The Universe view emits them via the
        // dedicated `cross_domain` edge kind instead.
        for r in &agg.references {
            if !local_aggs.contains(&r.target) { continue; }
            let to_id = format!("agg:{}", r.target);
            edges.push(format!(
                r#"{{"data":{{"source":{},"target":{},"kind":"references","alias":{}}}}}"#,
                json_str(&agg_id), json_str(&to_id), json_str(&r.name)
            ));
        }
    }

    // ── Policies ─────────────────────────────────────────────────
    for policy in &rt.domain.policies {
        let p_id = format!("pol:{}", policy.name);
        nodes.push(format!(
            r#"{{"data":{{"id":{},"label":{},"kind":"policy","on":{},"trigger":{}}}}}"#,
            json_str(&p_id),
            json_str(&policy.name),
            json_str(&policy.on_event),
            json_str(&policy.trigger_command),
        ));
        let evt_id = format!("evt:{}", policy.on_event);
        if event_seen.insert(policy.on_event.clone()) {
            nodes.push(format!(
                r#"{{"data":{{"id":{},"label":{},"kind":"event","emittedBy":""}}}}"#,
                json_str(&evt_id), json_str(&policy.on_event)
            ));
        }
        edges.push(format!(
            r#"{{"data":{{"source":{},"target":{},"kind":"triggers"}}}}"#,
            json_str(&evt_id), json_str(&p_id)
        ));
        let trigger = &policy.trigger_command;
        let target_cmd_id = format!("cmd:{}", trigger.split('.').last().unwrap_or(trigger));
        edges.push(format!(
            r#"{{"data":{{"source":{},"target":{},"kind":"triggers"}}}}"#,
            json_str(&p_id), json_str(&target_cmd_id)
        ));
    }

    // ── Process managers ─────────────────────────────────────────
    for pm in &rt.domain.process_managers {
        let pm_id = format!("pm:{}", pm.name);
        let states_json: Vec<String> = pm.states.iter()
            .map(|s| json_str(s)).collect();
        nodes.push(format!(
            r#"{{"data":{{"id":{},"label":{},"kind":"process_manager","correlatesBy":{},"startsOn":{},"states":[{}]}}}}"#,
            json_str(&pm_id),
            json_str(&pm.name),
            json_str(&pm.correlates_by),
            json_str(&pm.starts_on),
            states_json.join(","),
        ));
        // PM correlates with its starts_on event
        let evt_id = format!("evt:{}", pm.starts_on);
        if event_seen.insert(pm.starts_on.clone()) {
            nodes.push(format!(
                r#"{{"data":{{"id":{},"label":{},"kind":"event","emittedBy":""}}}}"#,
                json_str(&evt_id), json_str(&pm.starts_on)
            ));
        }
        edges.push(format!(
            r#"{{"data":{{"source":{},"target":{},"kind":"correlates"}}}}"#,
            json_str(&evt_id), json_str(&pm_id)
        ));
        // Each handler's event also correlates
        for h in &pm.handlers {
            let h_evt_id = format!("evt:{}", h.event_type);
            if event_seen.insert(h.event_type.clone()) {
                nodes.push(format!(
                    r#"{{"data":{{"id":{},"label":{},"kind":"event","emittedBy":""}}}}"#,
                    json_str(&h_evt_id), json_str(&h.event_type)
                ));
            }
            edges.push(format!(
                r#"{{"data":{{"source":{},"target":{},"kind":"correlates"}}}}"#,
                json_str(&h_evt_id), json_str(&pm_id)
            ));
        }
    }

    // Final integrity filter — drop edges whose source or target
    // wasn't emitted as a node. This catches every dangling-endpoint
    // case (cross-domain references, foreign events on policies,
    // policy-trigger commands declared in sibling domains). Without
    // this, Cytoscape silently aborts the entire render.
    let node_ids: std::collections::BTreeSet<String> = nodes.iter()
        .filter_map(|n| {
            // The node JSON is `{"data":{"id":"<id>", ...}}`. Extract
            // the id with a tiny scan ; serde would be heavier.
            let key = "\"id\":\"";
            let start = n.find(key)? + key.len();
            let rest = &n[start..];
            let end = rest.find('"')?;
            Some(rest[..end].to_string())
        })
        .collect();
    let edges: Vec<String> = edges.into_iter().filter(|e| {
        let mut ok = true;
        for key in &["\"source\":\"", "\"target\":\""] {
            if let Some(start) = e.find(key) {
                let s = start + key.len();
                let rest = &e[s..];
                if let Some(end) = rest.find('"') {
                    let id = &rest[..end];
                    if !node_ids.contains(id) { ok = false; break; }
                }
            }
        }
        ok
    }).collect();

    format!("[{}]", [nodes, edges].concat().join(","))
}
