//! Vector math — structural extraction and similarity
//!
//! Extracts a 9-dimensional vector from a Domain IR and computes
//! cosine similarity for nearest-archetype matching.
//!
//! Vector dimensions:
//!   [agg_count, cmds_per_agg, value_objects, policies,
//!    references, lifecycles, list_ofs, givens, fixtures]

use crate::ir::Domain;
use std::collections::HashMap;

/// Extract a 9-dimensional structural vector from a parsed domain.
pub fn extract_vector(domain: &Domain) -> Vec<f64> {
    let agg_count = domain.aggregates.len() as f64;
    let total_cmds: usize = domain.aggregates.iter().map(|a| a.commands.len()).sum();
    let cmds_per_agg = if agg_count > 0.0 { total_cmds as f64 / agg_count } else { 0.0 };
    let value_objects: usize = domain.aggregates.iter().map(|a| a.value_objects.len()).sum();
    let policies = domain.policies.len() as f64;
    let references: usize = domain.aggregates.iter().map(|a| a.references.len()).sum();
    let lifecycles = domain.aggregates.iter().filter(|a| a.lifecycle.is_some()).count() as f64;
    let list_ofs: usize = domain
        .aggregates
        .iter()
        .flat_map(|a| a.attributes.iter())
        .filter(|attr| attr.list)
        .count();
    let givens: usize = domain
        .aggregates
        .iter()
        .flat_map(|a| a.commands.iter())
        .map(|c| c.givens.len())
        .sum();
    let fixtures = domain.fixtures.len() as f64;

    vec![
        agg_count,
        cmds_per_agg,
        value_objects as f64,
        policies,
        references as f64,
        lifecycles,
        list_ofs as f64,
        givens as f64,
        fixtures,
    ]
}

/// Weighted cosine similarity. Aggregate count and commands/agg weighted 3x
/// to prefer domains of similar size over domains with similar ratios.
/// Delegates the math to `conceiver_common::cosine_similarity_weighted`
/// so behaviors_conceiver can't drift to a different similarity formula.
pub fn cosine_similarity(a: &[f64], b: &[f64]) -> f64 {
    // Weights: [aggs, cmds/agg, VOs, policies, refs, lifecycles, lists, givens, fixtures]
    let weights = [3.0, 3.0, 1.0, 2.0, 1.0, 1.0, 1.0, 1.0, 2.0];
    crate::conceiver_common::cosine_similarity_weighted(a, b, &weights)
}

/// Estimate a seed vector from a vision description using keyword hints.
pub fn seed_from_description(vision: &str) -> Vec<f64> {
    let hints = build_shape_hints();
    let base = vec![3.0, 3.5, 1.0, 2.0, 1.0, 1.0, 1.0, 1.0, 1.0];
    let words: Vec<String> = vision.to_lowercase().split(|c: char| !c.is_alphanumeric()).filter(|w| !w.is_empty()).map(String::from).collect();

    let matched: Vec<&Vec<f64>> = words
        .iter()
        .filter_map(|w| hints.get(w.as_str()))
        .collect();

    if matched.is_empty() {
        return base;
    }

    // Use max of hints, not average — pick the strongest signal per dimension
    base.iter()
        .enumerate()
        .map(|(i, b)| {
            let hint_max: f64 = matched.iter().map(|v| v[i]).fold(0.0_f64, f64::max);
            b.max(hint_max)
        })
        .collect()
}

fn build_shape_hints() -> HashMap<&'static str, Vec<f64>> {
    let mut m = HashMap::new();
    m.insert("lifecycle",      vec![3.0, 3.0, 1.0, 2.0, 1.0, 2.0, 1.0, 1.0, 0.0]);
    m.insert("pipeline",       vec![4.0, 4.0, 2.0, 3.0, 2.0, 2.0, 1.0, 1.0, 0.0]);
    m.insert("governance",     vec![5.0, 5.0, 3.0, 4.0, 2.0, 3.0, 1.0, 2.0, 2.0]);
    m.insert("science",        vec![4.0, 5.0, 2.0, 3.0, 1.0, 1.0, 1.0, 1.0, 3.0]);
    m.insert("biology",        vec![4.0, 6.0, 2.0, 3.0, 1.0, 2.0, 1.0, 1.0, 3.0]);
    m.insert("chemistry",      vec![4.0, 4.0, 2.0, 2.0, 1.0, 1.0, 1.0, 1.0, 3.0]);
    m.insert("physics",        vec![4.0, 5.0, 1.0, 3.0, 1.0, 2.0, 1.0, 1.0, 2.0]);
    m.insert("math",           vec![5.0, 5.0, 1.0, 3.0, 0.0, 1.0, 1.0, 0.0, 2.0]);
    m.insert("mathematics",    vec![5.0, 5.0, 1.0, 3.0, 0.0, 1.0, 1.0, 0.0, 2.0]);
    m.insert("finance",        vec![4.0, 4.0, 2.0, 3.0, 2.0, 2.0, 2.0, 2.0, 1.0]);
    m.insert("manufacturing",  vec![5.0, 5.0, 3.0, 4.0, 2.0, 3.0, 2.0, 2.0, 2.0]);
    m.insert("compliance",     vec![4.0, 4.0, 2.0, 4.0, 2.0, 3.0, 1.0, 2.0, 2.0]);
    m.insert("tracking",       vec![4.0, 3.0, 1.0, 2.0, 2.0, 2.0, 1.0, 0.0, 1.0]);
    m.insert("simple",         vec![2.0, 2.0, 1.0, 1.0, 0.0, 0.0, 1.0, 0.0, 0.0]);
    m.insert("complex",        vec![6.0, 5.0, 3.0, 4.0, 3.0, 3.0, 2.0, 2.0, 2.0]);
    m.insert("earth",          vec![4.0, 5.0, 2.0, 3.0, 1.0, 1.0, 1.0, 1.0, 3.0]);
    m.insert("geological",     vec![4.0, 5.0, 2.0, 3.0, 1.0, 1.0, 1.0, 1.0, 3.0]);
    m.insert("audit",          vec![4.0, 4.0, 2.0, 4.0, 2.0, 3.0, 1.0, 2.0, 2.0]);
    m.insert("logging",        vec![3.0, 3.0, 1.0, 2.0, 1.0, 2.0, 1.0, 1.0, 1.0]);
    m
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_cosine_similarity_identical() {
        let v = vec![1.0, 2.0, 3.0];
        let sim = cosine_similarity(&v, &v);
        assert!((sim - 1.0).abs() < 1e-10);
    }

    #[test]
    fn test_cosine_similarity_orthogonal() {
        let a = vec![1.0, 0.0];
        let b = vec![0.0, 1.0];
        let sim = cosine_similarity(&a, &b);
        assert!(sim.abs() < 1e-10);
    }

    #[test]
    fn test_seed_from_description_with_keywords() {
        let v = seed_from_description("a science of biology");
        assert_eq!(v.len(), 9);
        assert!(v[0] > 2.0); // should be influenced by hints
    }
}
