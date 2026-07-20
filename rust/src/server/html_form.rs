//! Form rendering — type-aware inputs and reference pickers
//!
//! Renders one HTML form per command. Inspects the Attribute IR to
//! pick the right input element :
//!   String → text input
//!   Bool / Boolean → checkbox
//!   Int / Integer → number step=1
//!   Decimal / Float → number step=0.01
//!   ValueObject → wrapper-VO unwrap (one :value String) or nested
//!                 fields ; enum-detection is out of scope until the
//!                 IR carries member literals.
//! Reference fields render as <select> populated from the live
//! repository via Runtime::all().
//!
//! Required-field heuristic : attributes without a `default` are
//! treated as required (label asterisk + HTML required attr).
//!
//! Usage:
//!   let html = render_command_form(domain, agg, cmd, rt);
//!
//! [antibody-exempt: form rendering — kernel surface alongside
//!  html_domain.rs ; i106 + i107 + i109 walking-skeleton upgrades.]

use crate::ir::{Aggregate, Attribute, Command, Reference};
use crate::runtime::Runtime;
use super::html_shared::{display_name, esc};

/// Render a complete `<form>` for one command. Includes every
/// attribute (typed input) and every reference (select picker), with
/// a submit button that dispatches via the JSON endpoint.
pub fn render_command_form(domain: &str, agg: &Aggregate, cmd: &Command, rt: &Runtime) -> String {
    let mut s = String::new();
    s.push_str(&format!(
        r#"<form onsubmit="return wizardSubmit(this, '{domain}', '{cmd_name}')" class="space-y-2">"#,
        domain = esc(domain),
        cmd_name = esc(&cmd.name),
    ));

    if !cmd.description.as_deref().unwrap_or("").is_empty() {
        s.push_str(&format!(
            r#"<p class="text-xs text-gray-400 mb-2">{}</p>"#,
            esc(cmd.description.as_deref().unwrap_or("")),
        ));
    }

    // Reference pickers — one <select> per cross-aggregate reference.
    for r in &cmd.references {
        s.push_str(&reference_picker(r, rt));
    }

    // Attribute inputs — typed per attr_type. References that double
    // as attributes (e.g. `attribute Customer`) are detected by VO
    // lookup ; when the type matches an aggregate name we render a
    // picker instead of a text box.
    let cols = if cmd.attributes.len() + cmd.references.len() <= 3 {
        "grid-cols-1"
    } else {
        "grid-cols-2"
    };
    s.push_str(&format!(r#"<div class="grid {} gap-2">"#, cols));
    for attr in &cmd.attributes {
        s.push_str(&field_input(agg, attr, rt));
    }
    s.push_str("</div>");

    let btn_label = display_name(&cmd.name);
    s.push_str(&format!(
        r#"<button type="submit" class="w-full px-4 py-2 bg-brand/10 border border-brand/30 rounded-lg text-brand text-sm font-medium hover:bg-brand/20 transition mt-2">{label}</button>
  <div class="wizard-result"></div>
</form>"#,
        label = esc(&btn_label),
    ));
    s
}

/// One labelled input matching the attribute's declared type. Falls
/// back to a text input for unknown / nested value-object types.
pub fn field_input(agg: &Aggregate, attr: &Attribute, rt: &Runtime) -> String {
    let label = display_name(&attr.name);
    // Words match state (2026-07-18) : the asterisk marks what the gate
    // ENFORCES — the explicit `required: true` flag — not the aspirational
    // no-default heuristic. A form that claims required while the door
    // waves absence through is the lie the payload gate retired.
    let required = attr.required;
    let req_mark = if required { r#" <span class="text-red-400">*</span>"# } else { "" };
    let req_attr = if required { " required" } else { "" };

    // References render as the record browser (richer than the schema's
    // id-string). EVERYTHING else is a projection of the command's schema :
    // json_schema::attr_schema is the ONE place that decides enum-vs-type,
    // shared with external validators and the MCP door — so "what the form
    // shows" can never diverge from "what the schema says" (2026-07-19).
    if let Some(target) = aggregate_by_name(rt, &attr.attr_type) {
        return labelled(&label, req_mark, &reference_browser_button(&attr.name, target));
    }
    let prop = crate::projection::json_schema::attr_schema(agg, attr);
    let input = input_from_schema(agg, attr, &prop, req_attr);
    // A DECLARED `hint:` is VISIBLE guidance, rendered under the field — not
    // the input's `title`, which is only a hover tooltip / post-submit
    // popup and so tells a user nothing while they are typing. The
    // mechanical fallback stays on the `title` (it is a mismatch message,
    // wrong to show before the user has done anything). Only the author's
    // own words go on the page.
    let hint_line = prop
        .get("x-hecks-hint")
        .and_then(|h| h.as_str())
        .map(|h| format!(
            r#"<p class="text-xs text-gray-500 mt-1">{}</p>"#,
            esc(h)
        ))
        .unwrap_or_default();
    labelled(&label, req_mark, &format!("{}{}", input, hint_line))
}

/// Render one input from a schema property (`{type, enum}`). The schema
/// carries the CONTRACT (which values, which primitive) ; the form adds
/// PRESENTATION only — a member VO's " · " option labels and the
/// "— pick —" placeholder. Enum → dropdown ; integer/number/boolean →
/// typed input ; else text.
fn input_from_schema(
    agg: &Aggregate,
    attr: &Attribute,
    prop: &serde_json::Value,
    req_attr: &str,
) -> String {
    let label = display_name(&attr.name);
    if let Some(en) = prop.get("enum").and_then(|e| e.as_array()) {
        // Presentation only : member VOs get rich " · " labels ; scalar
        // enums show the value itself. The VALUES come from the schema.
        let pairs: Vec<(String, String)> = agg
            .value_objects
            .iter()
            .find(|v| v.name == attr.attr_type && !v.members.is_empty())
            .map(|vo| {
                vo.members
                    .iter()
                    .filter_map(|m| {
                        m.first().map(|(_, disc)| {
                            let text = m.iter().map(|(_, x)| x.as_str()).collect::<Vec<_>>().join(" · ");
                            (disc.clone(), text)
                        })
                    })
                    .collect()
            })
            .unwrap_or_else(|| {
                en.iter()
                    .filter_map(|v| v.as_str().map(|s| (s.to_string(), s.to_string())))
                    .collect()
            });
        let mut opts = String::new();
        let selected_default = attr.default.as_deref().unwrap_or("");
        if selected_default.is_empty() {
            opts.push_str(&format!(
                r#"<option value="" disabled selected>— pick {} —</option>"#,
                esc(&label)
            ));
        }
        for (val, text) in &pairs {
            let sel = if val == selected_default { " selected" } else { "" };
            opts.push_str(&format!(r#"<option value="{}"{}>{}</option>"#, esc(val), sel, esc(text)));
        }
        return format!(
            r#"<select name="{}"{} class="bg-surface-0 border border-surface-4 rounded px-3 py-1.5 text-sm text-gray-100 focus:border-brand focus:outline-none w-full">{}</select>"#,
            esc(&attr.name), req_attr, opts
        );
    }
    if prop.get("type").and_then(|t| t.as_str()) == Some("boolean") {
        return checkbox(&attr.name, req_attr);
    }
    // Money (cents convention) : the wire is cents but humans think in
    // dollars, so DISPLAY dollars (min/max ÷100, step 0.01) and mark the
    // input `data-money="cents"` — wizardSubmit multiplies ×100 back to the
    // cents the gate expects. The schema minimum stays cents (the contract).
    if prop.get("x-hecks-money").is_some() {
        let mut extra = String::from(r#" step="0.01" data-money="cents""#);
        if let Some(mn) = prop.get("minimum").and_then(|m| m.as_i64()) {
            extra.push_str(&format!(r#" min="{:.2}""#, mn as f64 / 100.0));
        }
        if let Some(mx) = prop.get("maximum").and_then(|m| m.as_i64()) {
            extra.push_str(&format!(r#" max="{:.2}""#, mx as f64 / 100.0));
        }
        return text_input(&attr.name, &format!("{} ($)", label), "number", &extra, req_attr);
    }
    // `type="email"` for an email-shaped field — the browser gives it the
    // mobile @ keyboard, native validation and autofill, all free. Detected
    // from the attribute NAME (`email`, `*_email`) rather than the pattern,
    // because the same address can be written a dozen ways and matching the
    // regex would be brittle ; the name is the domain's own signal. The
    // `pattern` below still rides along, so a stricter shape than the
    // browser's built-in email check is honoured too.
    let looks_like_email =
        attr.name == "email" || attr.name.ends_with("_email");
    let (input_type, step): (&str, &str) = match prop.get("type").and_then(|t| t.as_str()) {
        Some("integer") => ("number", r#" step="1""#),
        Some("number") => ("number", r#" step="any""#),
        _ if looks_like_email => ("email", ""),
        _ => ("text", ""),
    };
    // min / max come straight from the schema's minimum / maximum — the
    // browser then refuses an out-of-bounds value before it ever reaches
    // the gate (the invariant enforced twice : field hint + payload gate).
    let mut extra = step.to_string();
    if let Some(mn) = prop.get("minimum").and_then(|m| m.as_i64()) {
        extra.push_str(&format!(r#" min="{}""#, mn));
    }
    if let Some(mx) = prop.get("maximum").and_then(|m| m.as_i64()) {
        extra.push_str(&format!(r#" max="{}""#, mx));
    }
    // `pattern` comes straight from the schema, exactly as min/max do, so the
    // browser refuses a mis-shaped value before it reaches the gate. The subset
    // a bluebook may declare is the Ruby-Rust intersection (pattern_subset),
    // which is also valid ECMAScript -- anchors, classes, quantifiers,
    // alternation, plain groups -- so one source text means the same thing in
    // all THREE engines, the browser included.
    if let Some(p) = prop.get("pattern").and_then(|p| p.as_str()) {
        extra.push_str(&format!(concat!(" pattern=", "\"{}\""), esc_pattern_attr(p)));
        // `title` is what the browser shows on a pattern mismatch instead of
        // its generic "Please match the requested format". Prefer the
        // author's declared `hint:` ; fall back to a mechanical message so a
        // pattern is NEVER enforced with no guidance — a silent refusal is
        // the worst form feedback there is. The generic fallback names no
        // regex : "^[^@\s]+@..." tells a user nothing.
        let title = prop
            .get("x-hecks-hint")
            .and_then(|h| h.as_str())
            .map(str::to_string)
            .unwrap_or_else(|| format!("{} isn't in the expected format", label));
        extra.push_str(&format!(concat!(" title=", "\"{}\""), esc(&title)));
    }
    text_input(&attr.name, &label, input_type, &extra, req_attr)
}

/// Escape a regex for a double-quoted HTML attribute. ONLY `&` and `"` can
/// break out ; every other regex metacharacter is inert in attribute position
/// and must survive VERBATIM -- escaping more would silently change the
/// pattern the browser enforces.
fn esc_pattern_attr(s: &str) -> String {
    s.replace('&', "&amp;").replace('"', "&quot;")
}

/// Render the <label> wrapper around an input. The asterisk for
/// required fields is appended inside the label so the screen reader
/// reads "Customer star" the way browsers handle required hints.
fn labelled(label: &str, req_mark: &str, body: &str) -> String {
    format!(
        r#"<div><label class="block text-xs text-gray-400 mb-1">{label}{mark}</label>{body}</div>"#,
        label = esc(label),
        mark = req_mark,
        body = body,
    )
}

fn text_input(name: &str, placeholder: &str, input_type: &str, step: &str, req: &str) -> String {
    format!(
        r#"<input name="{name}" type="{ty}"{step}{req} placeholder="{ph}" class="bg-surface-0 border border-surface-4 rounded px-3 py-1.5 text-sm text-gray-100 focus:border-brand focus:outline-none w-full">"#,
        name = esc(name),
        ty = input_type,
        step = step,
        req = req,
        ph = esc(placeholder),
    )
}

fn checkbox(name: &str, req: &str) -> String {
    format!(
        r#"<input name="{name}" type="checkbox" value="true"{req} class="h-4 w-4 rounded bg-surface-0 border-surface-4 text-brand focus:ring-brand">"#,
        name = esc(name),
        req = req,
    )
}

/// Reference picker = hidden input + browser button. Clicking the button
/// opens the record-browser modal (`openRefBrowser` in html_wizard.rs),
/// which fetches the target aggregate's records LIVE from
/// `/domains/{d}/aggregates/{Target}` and shows each as attribute chips —
/// pick a child by seeing it, never by decoding a numeric id. The hidden
/// input still submits `name = rec.id`, so the dispatch resolution chain
/// (`command_dispatch.rs` resolved_id) is untouched. `data-attrs` /
/// `data-labels` carry the declared attribute order from the IR — the
/// same ordering source as the live records table.
fn reference_browser_button(name: &str, target: &Aggregate) -> String {
    let target_label = display_name(&target.name);
    let attr_names: Vec<&str> = target.attributes.iter().map(|a| a.name.as_str()).collect();
    let attr_labels: Vec<String> = target.attributes.iter().map(|a| display_name(&a.name)).collect();
    format!(
        r#"<input type="hidden" name="{name}" value="" data-ref="{target_name}"><button type="button" onclick="openRefBrowser(this)" data-target="{target_name}" data-target-label="{label}" data-attrs="{attrs}" data-labels="{labels}" class="bg-surface-0 border border-surface-4 rounded px-3 py-1.5 text-sm text-gray-500 hover:border-brand focus:border-brand focus:outline-none w-full text-left transition">— pick {label} —</button>"#,
        name = esc(name),
        target_name = esc(&target.name),
        label = esc(&target_label),
        attrs = esc(&attr_names.join(",")),
        labels = esc(&attr_labels.join(",")),
    )
}

/// One reference picker labelled "Customer", "Service Address", …
fn reference_picker(r: &Reference, rt: &Runtime) -> String {
    let target = match aggregate_by_name(rt, &r.target) {
        Some(a) => a,
        None => return String::new(),
    };
    let label = display_name(&r.target);
    labelled(
        &label,
        r#" <span class="text-red-400">*</span>"#,
        &reference_browser_button(&r.name, target),
    )
}

fn aggregate_by_name<'a>(rt: &'a Runtime, name: &str) -> Option<&'a Aggregate> {
    rt.domain.aggregates.iter().find(|a| a.name == name)
}
