# lib/hecks_specializer/validator.rb
#
# Hecks::Specializer::Validator — emits hecks_life/src/validator.rs
# byte-identical to the hand-written source, from validator_shape.fixtures.
#
# Moved from bin/specialize-validator as part of the Phase A/B
# consolidation. Behaviour is unchanged; loader + CLI now live in
# the driver (lib/hecks_specializer.rb + bin/specialize).

module Hecks
  module Specializer
    class Validator
      include Target

      SHAPE = REPO_ROOT.join("hecks_conception/capabilities/validator_shape/fixtures/validator_shape.fixtures")
      TARGET_RS = REPO_ROOT.join("hecks_life/src/validator.rs")

      def emit
        [
          emit_header,
          emit_imports,
          emit_entry_point,
          emit_rule(find_rule("unique_aggregate_names")),
          emit_rule(find_rule("aggregates_have_commands")),
          emit_command_naming_support,
          emit_rule(find_rule("command_naming")),
          emit_rule(find_rule("valid_references")),
          emit_rule(find_rule("valid_policy_triggers")),
          emit_rule(find_rule("no_duplicate_commands")),
        ].join
      end

      private

      def find_rule(rust_fn_name)
        by_aggregate("ValidationRule").find { |r| r["attrs"]["rust_fn_name"] == rust_fn_name } or
          raise "no ValidationRule fixture with rust_fn_name=#{rust_fn_name}"
      end

      def emit_header
        <<~RS
          //! Domain validator — checks a parsed domain for DDD consistency
          //!
          //! GENERATED FILE — do not edit.
          //! Source:    hecks_conception/capabilities/validator_shape/
          //! Regenerate: bin/specialize validator --output hecks_life/src/validator.rs
          //! Contract:  specializer.hecksagon :specialize_validator shell adapter
          //! Tests:     hecks_life/tests/validator_rules_test.rs (moved out for i51 Phase A commit 4)
          //!
          //! Ports the Ruby Hecks::Validator rules to Rust. Each rule inspects
          //! the Domain IR and returns error strings. An empty vec means valid.
          //!
          //! Usage:
          //!   let errors = validator::validate(&domain);
          //!   if errors.is_empty() { println!("VALID"); }

        RS
      end

      def emit_imports
        <<~RS
          use crate::ir::Domain;
          use std::collections::HashSet;

        RS
      end

      def emit_entry_point
        entry = by_aggregate("ValidatorEntryPoint").first
        attrs = entry["attrs"]
        rules = attrs["rule_order"].split(",").map(&:strip)
        lines = rules.map { |r| "    errors.extend(#{r}(domain));" }
        <<~RS
          /// Run all validation rules and return collected errors.
          pub fn #{attrs["fn_name"]}(domain: &Domain) -> #{attrs["returns"]} {
              let mut #{attrs["collects_into"]} = vec![];
          #{lines.join("\n")}
              #{attrs["collects_into"]}
          }

        RS
      end

      def emit_rule(rule)
        case rule["attrs"]["check_kind"]
        when "unique"          then emit_unique(rule)
        when "non_empty"       then emit_non_empty(rule)
        when "first_word_verb" then emit_first_word_verb(rule)
        when "reference_valid" then emit_reference_valid(rule)
        when "trigger_valid"   then emit_trigger_valid(rule)
        when "unique_across"   then emit_unique_across(rule)
        else raise "unknown check_kind: #{rule["attrs"]["check_kind"]}"
        end
      end

      def emit_unique(rule)
        a = rule["attrs"]
        <<~RS
          /// #{a["description"]}.
          fn #{a["rust_fn_name"]}(domain: &Domain) -> Vec<String> {
              let mut seen = HashSet::new();
              let mut errors = vec![];
              for agg in &domain.aggregates {
                  if !seen.insert(&agg.name) {
                      errors.push(format!("Duplicate aggregate name: {}", agg.name));
                  }
              }
              errors
          }

        RS
      end

      def emit_non_empty(rule)
        a = rule["attrs"]
        <<~RS
          /// #{a["description"]}.
          fn #{a["rust_fn_name"]}(domain: &Domain) -> Vec<String> {
              domain
                  .aggregates
                  .iter()
                  .filter(|a| a.commands.is_empty())
                  .map(|a| format!("{} has no commands", a.name))
                  .collect()
          }

        RS
      end

      def emit_command_naming_support
        suffixes = by_aggregate("SuffixTable").map { |f| f["attrs"] }
        nouns = suffixes.select { |s| s["table"] == "noun" }.map { |s| s["suffix"] }
        adjs  = suffixes.select { |s| s["table"] == "adj" }.map { |s| s["suffix"] }

        exceptions = by_aggregate("ExceptionWord").map { |f| f["attrs"] }
        false_pos = exceptions.select { |e| e["category"] == "false_positive" }.map { |e| e["word"] }

        <<~RS
          /// Command names must start with a verb — detected by morphological patterns.
          /// Flipped logic: a command is imperative by definition. We only reject if
          /// the first word is provably NOT a verb (noun/adjective suffixes).
          /// Everything else passes — commands are verbs until proven otherwise.

          /// Suffixes that prove a word is a noun — not a verb.
          const NOUN_SUFFIXES: &[&str] = &[
          #{format_suffix_list(nouns, 7)}
          ];

          /// Suffixes that prove a word is an adjective — not a verb.
          const ADJ_SUFFIXES: &[&str] = &[
          #{format_suffix_list(adjs, 8)}
          ];

          /// Words that look like they could be verbs but are actually nouns
          /// when used as command first-words. Very short list — only add
          /// proven false positives.
          const FALSE_POSITIVES: &[&str] = &[
          #{format_suffix_list(false_pos, 7)}
          ];

          /// Extract the first word from a PascalCase name.
          fn first_word(name: &str) -> String {
              let mut word = String::new();
              for (i, c) in name.chars().enumerate() {
                  if i > 0 && c.is_uppercase() { break; }
                  word.push(c);
              }
              word
          }

          /// A command first-word is NOT a verb if it matches noun/adjective patterns.
          /// Everything else is assumed to be a verb — commands are imperative.
          fn is_not_verb(word: &str) -> bool {
              let lower = word.to_lowercase();

              // Too short to classify — single char is fine (commands like "X" are weird but not invalid)
              if lower.len() < 2 { return false; }

              // Known false positives — articles, possessives, adjectives used as names
              if FALSE_POSITIVES.iter().any(|fp| *fp == word) { return true; }

              // Words ending in noun suffixes that are actually verbs
              let verb_exceptions = #{format_verb_exceptions};
              if verb_exceptions.iter().any(|v| lower == *v) { return false; }

              // Verb suffixes — if these match, the word is a verb even if it
              // also matches a noun/adjective suffix (verb wins)
              let verb_suffixes = #{format_verb_suffixes};
              let has_verb_suffix = verb_suffixes.iter().any(|s| lower.ends_with(s));

              // Noun suffixes — if it ends like a noun AND doesn't have a verb suffix, reject
              for suffix in NOUN_SUFFIXES {
                  if lower.ends_with(suffix) && lower.len() > suffix.len() + 1 && !has_verb_suffix {
                      return true;
                  }
              }

              // Adjective suffixes — same logic
              for suffix in ADJ_SUFFIXES {
                  if lower.ends_with(suffix) && lower.len() > suffix.len() + 1 && !has_verb_suffix {
                      return true;
                  }
              }

              // Everything else is a verb. Commands are imperative by definition.
              false
          }

        RS
      end

      def format_suffix_list(items, per_line)
        items.each_slice(per_line).map do |chunk|
          "    " + chunk.map { |s| "\"#{s}\"" }.join(", ") + ","
        end.join("\n")
      end

      def format_verb_exceptions
        words = by_aggregate("ExceptionWord").map { |f| f["attrs"] }
                  .select { |e| e["category"] == "verb_exception" }
                  .map { |e| e["word"] }
        lines = []
        lines << "[\"#{words[0..2].join('", "')}\", \"#{words[3]}\","
        lines << "        \"#{words[4..9].join('", "')}\","
        lines << "        \"#{words[10..14].join('", "')}\","
        lines << "        \"#{words[15..19].join('", "')}\","
        lines << "        \"#{words[20..23].join('", "')}\"]"
        lines.join("\n")
      end

      def format_verb_suffixes
        suffixes = by_aggregate("SuffixTable").map { |f| f["attrs"] }
                     .select { |s| s["table"] == "verb" }
                     .map { |s| s["suffix"] }
        head = suffixes[0..6].map { |s| "\"#{s}\"" }.join(", ")
        tail = suffixes[7..].map { |s| "\"#{s}\"" }.join(", ")
        "[#{head},\n        #{tail}]"
      end

      def emit_first_word_verb(rule)
        <<~RS
          fn #{rule["attrs"]["rust_fn_name"]}(domain: &Domain) -> Vec<String> {
              let mut errors = vec![];
              for agg in &domain.aggregates {
                  for cmd in &agg.commands {
                      let word = first_word(&cmd.name);
                      if is_not_verb(&word) {
                          errors.push(format!(
                              "Command {} in {} starts with '{}' which looks like a {} — commands should start with a verb",
                              cmd.name, agg.name, word,
                              if NOUN_SUFFIXES.iter().any(|s| word.to_lowercase().ends_with(s)) { "noun" } else { "adjective" }
                          ));
                      }
                  }
              }
              errors
          }

        RS
      end

      def emit_reference_valid(rule)
        a = rule["attrs"]
        <<~RS
          /// References must target existing aggregate roots.
          fn #{a["rust_fn_name"]}(domain: &Domain) -> Vec<String> {
              let agg_names: HashSet<&str> = domain
                  .aggregates
                  .iter()
                  .map(|a| a.name.as_str())
                  .collect();

              let mut errors = vec![];
              for agg in &domain.aggregates {
                  for reference in &agg.references {
                      if reference.domain.is_some() {
                          continue; // cross-domain refs validated elsewhere
                      }
                      if !agg_names.contains(reference.target.as_str()) {
                          errors.push(format!(
                              "{} references unknown aggregate: {}",
                              agg.name, reference.target
                          ));
                      }
                  }
                  for cmd in &agg.commands {
                      for reference in &cmd.references {
                          if reference.domain.is_some() {
                              continue;
                          }
                          if !agg_names.contains(reference.target.as_str()) {
                              errors.push(format!(
                                  "Command {} references unknown aggregate: {}",
                                  cmd.name, reference.target
                              ));
                          }
                      }
                  }
              }
              errors
          }

        RS
      end

      def emit_trigger_valid(rule)
        a = rule["attrs"]
        <<~RS
          /// Policy triggers must name existing commands.
          fn #{a["rust_fn_name"]}(domain: &Domain) -> Vec<String> {
              let all_commands: HashSet<&str> = domain
                  .aggregates
                  .iter()
                  .flat_map(|a| a.commands.iter().map(|c| c.name.as_str()))
                  .collect();

              domain
                  .policies
                  .iter()
                  .filter(|p| p.target_domain.is_none()) // skip cross-domain
                  .filter(|p| !all_commands.contains(p.trigger_command.as_str()))
                  .map(|p| {
                      format!(
                          "Policy {} triggers unknown command: {}",
                          p.name, p.trigger_command
                      )
                  })
                  .collect()
          }

        RS
      end

      def emit_unique_across(rule)
        a = rule["attrs"]
        <<~RS
          /// No two commands across all aggregates should share the same name.
          fn #{a["rust_fn_name"]}(domain: &Domain) -> Vec<String> {
              let mut seen = HashSet::new();
              let mut errors = vec![];
              for agg in &domain.aggregates {
                  for cmd in &agg.commands {
                      if !seen.insert(&cmd.name) {
                          errors.push(format!(
                              "Duplicate command name: {} (in {})",
                              cmd.name, agg.name
                          ));
                      }
                  }
              }
              errors
          }
        RS
      end
    end

    register :validator, Validator
  end
end
