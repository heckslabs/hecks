# lib/hecks_specializer/diagnostic_validator.rb
#
# Hecks::Specializer::DiagnosticValidator — base class for the Phase B
# diagnostic-style validator retirements (duplicate_policy, lifecycle, io).
#
# GENERATED FILE — do not edit.
# Source:    hecks_conception/capabilities/diagnostic_validator_meta_shape/
# Regenerate: bin/specialize meta_diagnostic_validator --output lib/hecks_specializer/diagnostic_validator.rb
# Contract:  specializer.hecksagon :specialize_meta_diagnostic_validator shell adapter
#
# Each subclass defines:
#   SHAPE      — path to its <target>_validator_shape.fixtures
#   TARGET_RS  — path to the .rs file it emits
#
# The base class handles the emission pipeline:
#   header → imports → Report (by report_kind) → helpers → rule
#
# Shape schema (identical across subclasses):
#
#   DiagnosticValidator (1 row):
#     module, doc_snippet, imports, report_kind, rule_fn_name,
#     rule_signature, check_body_snippet
#
#   DiagnosticHelper (N rows):
#     validator, name, doc_comment, signature, body_snippet, order
#
# report_kind dispatches to canned Report templates:
#   flat                     — findings: Vec<Finding>, errors/passes
#   flat_with_strict         — + warnings, passes(strict)
#   partitioned_with_strict  — static + runtime findings, strict
#
# Empty-body helpers (like #[allow(dead_code)] stubs) emit inline:
# `fn x() {}` instead of `fn x() {\n}`.
