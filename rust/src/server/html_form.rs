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

use crate::ir::{Aggregate, Attribute, Command, Reference, ValueObject};
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
    let lower = attr.attr_type.to_lowercase();

    // Reference-by-name : when attr_type matches a known aggregate,
    // render a record picker.
    if let Some(target) = aggregate_by_name(rt, &attr.attr_type) {
        return labelled(
            &label,
            req_mark,
            &reference_browser_button(&attr.name, target),
        );
    }

    // Value-object lookup : a wrapper VO (single inner attribute named
    // `:value`) unwraps to its inner type so `attribute :bin_count,
    // BinCount` where `BinCount` wraps `attribute :value, Integer`
    // renders as a numeric input rather than text. Multi-field VOs
    // still flatten to text for now.
    if let Some(vo) = value_object_by_name(agg, &attr.attr_type) {
        if let Some(inner) = wrapper_inner_type(vo) {
            let body = match inner.as_str() {
                "bool" | "boolean" => checkbox(&attr.name, req_attr),
                "int" | "integer" => text_input(&attr.name, &label, "number", r#" step="1""#, req_attr),
                "decimal" => text_input(&attr.name, &label, "number", r#" step="0.01""#, req_attr),
                "float" => text_input(&attr.name, &label, "number", r#" step="any""#, req_attr),
                _ => text_input(&attr.name, &label, "text", "", req_attr),
            };
            return labelled(&label, req_mark, &body);
        }
        return labelled(
            &label,
            req_mark,
            &text_input(&attr.name, &label, "text", "", req_attr),
        );
    }

    let body = match lower.as_str() {
        "bool" | "boolean" => checkbox(&attr.name, req_attr),
        "int" | "integer" => text_input(&attr.name, &label, "number", r#" step="1""#, req_attr),
        "decimal" => text_input(&attr.name, &label, "number", r#" step="0.01""#, req_attr),
        "float" => text_input(&attr.name, &label, "number", r#" step="any""#, req_attr),
        _ => text_input(&attr.name, &label, "text", "", req_attr),
    };
    labelled(&label, req_mark, &body)
}

/// If `vo` is a wrapper value object — exactly one attribute, named
/// `value` — return its inner type lowercased. Otherwise None.
/// Matches the common `BinCount = attribute :value, Integer` shape used
/// across bin-buddy ; renders the wrapped int/decimal/bool through to
/// a typed input on the form.
fn wrapper_inner_type(vo: &ValueObject) -> Option<String> {
    if vo.attributes.len() != 1 { return None; }
    let inner = &vo.attributes[0];
    if inner.name != "value" { return None; }
    Some(inner.attr_type.to_lowercase())
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

fn value_object_by_name<'a>(agg: &'a Aggregate, name: &str) -> Option<&'a ValueObject> {
    agg.value_objects.iter().find(|v| v.name == name)
}
