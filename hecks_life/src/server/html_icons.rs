//! Icon mappings — domain-level and aggregate-level emoji icons
//!
//! Keyword-based icon selection for sidebar (domain_icon) and
//! module cards (module_icon).
//!
//! Usage:
//!   let icon = domain_icon("manufacturing");
//!   let icon = module_icon("BuyerPersona");

/// Return an emoji icon for a domain based on keyword matching
pub fn domain_icon(name: &str) -> &'static str {
    let lower = name.to_lowercase();
    if lower.contains("brand") { return "\u{1F3AF}"; }
    if lower.contains("claim") { return "\u{1F4CB}"; }
    if lower.contains("compliance") || lower.contains("regulatory") { return "\u{2696}\u{FE0F}"; }
    if lower.contains("persona") || lower.contains("customer") { return "\u{1F465}"; }
    if lower.contains("demand") { return "\u{1F4CA}"; }
    if lower.contains("distribution") { return "\u{1F69A}"; }
    if lower.contains("lab") { return "\u{1F52C}"; }
    if lower.contains("formulation") { return "\u{1F9EA}"; }
    if lower.contains("inventory") { return "\u{1F4E6}"; }
    if lower.contains("manufactur") { return "\u{1F3ED}"; }
    if lower.contains("pricing") { return "\u{1F4B0}"; }
    if lower.contains("quality") { return "\u{2705}"; }
    if lower.contains("storefront") { return "\u{1F6D2}"; }
    if lower.contains("supply") { return "\u{1F517}"; }
    if lower.contains("catalog") { return "\u{1F4E6}"; }
    "\u{1F4CB}"
}

/// Return an emoji icon for an aggregate/module based on keyword matching
pub fn module_icon(name: &str) -> &'static str {
    let lower = name.to_lowercase();
    if lower.contains("persona") { return "👤"; }
    if lower.contains("journey") { return "🗺️"; }
    if lower.contains("insight") { return "💡"; }
    if lower.contains("channel") && lower.contains("fit") { return "📡"; }
    if lower.contains("competitor") { return "🏆"; }
    if lower.contains("formula") && lower.contains("exp") { return "🔬"; }
    if lower.contains("formula") { return "🧪"; }
    if lower.contains("lab") && lower.contains("test") { return "🔬"; }
    if lower.contains("thesis") || lower.contains("market") { return "📈"; }
    if lower.contains("preview") { return "👁️"; }
    if lower.contains("impact") { return "💥"; }
    if lower.contains("pipeline") { return "📊"; }
    if lower.contains("intelligence") { return "🕵️"; }
    if lower.contains("brand") && lower.contains("position") { return "🎯"; }
    if lower.contains("campaign") { return "📢"; }
    if lower.contains("review") { return "⭐"; }
    if lower.contains("order") { return "📋"; }
    if lower.contains("inventory") { return "📦"; }
    if lower.contains("supplier") { return "🏭"; }
    if lower.contains("material") { return "⚗️"; }
    if lower.contains("bill") { return "📃"; }
    if lower.contains("purchase") { return "💳"; }
    if lower.contains("quality") { return "✅"; }
    if lower.contains("price") { return "💰"; }
    if lower.contains("violation") { return "⚠️"; }
    if lower.contains("policy") { return "📜"; }
    if lower.contains("sds") || lower.contains("safety") { return "☢️"; }
    if lower.contains("jurisdiction") { return "⚖️"; }
    if lower.contains("audit") { return "🔍"; }
    if lower.contains("obligation") { return "📌"; }
    if lower.contains("label") { return "🏷️"; }
    if lower.contains("hazmat") || lower.contains("shipping") { return "🚛"; }
    if lower.contains("environment") { return "🌿"; }
    if lower.contains("change") { return "🔄"; }
    if lower.contains("claim") || lower.contains("warranty") { return "🛡️"; }
    if lower.contains("return") { return "↩️"; }
    if lower.contains("complaint") { return "📝"; }
    if lower.contains("demand") || lower.contains("signal") { return "📊"; }
    if lower.contains("forecast") { return "🔮"; }
    if lower.contains("reorder") || lower.contains("recommend") { return "🔔"; }
    if lower.contains("storefront") || lower.contains("site") { return "🌐"; }
    if lower.contains("product") && lower.contains("list") { return "🛍️"; }
    if lower.contains("cart") { return "🛒"; }
    if lower.contains("account") { return "👤"; }
    if lower.contains("science") { return "🔬"; }
    if lower.contains("product") { return "📦"; }
    if lower.contains("brand") { return "🏷️"; }
    if lower.contains("traceab") { return "🔗"; }
    "📋"
}
