# lib/hecks_specializer/meta_diagnostic_validator.rb
#
# Hecks::Specializer::MetaDiagnosticValidator — Phase C PC-2.
#
# First meta-specializer that regenerates a FULL Ruby class (not just
# a thin subclass shell). Reads RubyClass + RubyMethod (+ optional
# RubyConstant) fixture rows from diagnostic_validator_meta_shape.fixtures
# and emits lib/hecks_specializer/<target>.rb byte-identical.
#
# Emission pipeline:
#   1. doc block (from RubyClass.doc_snippet, verbatim)
#   2. module nesting open (from RubyClass.module_path)
#   3. class declaration + include lines
#   4. constants (if any RubyConstant rows match class_name), sorted
#      by order, each preceded/separated by a blank line
#   5. blank line
#   6. public methods (RubyMethod rows with visibility=public) in order
#   7. blank line + "private" + blank line
#   8. private methods in order
#   9. class close
#  10. IF register_target_name non-empty: blank line + register call
#      at class-close depth (inside the innermost module)
#  11. module nesting close (ends)
#
# Method bodies come from .rb.frag snippets, read raw. The specializer
# only arranges the skeleton; bodies are the author's Ruby.
#
# Subclasses override `self.target_class_name` to pick which RubyClass
# row to emit for. Default picks the first row — kept for the pilot
# (DiagnosticValidator) which was the sole row when PC-2 landed.
#
# Scope: the base class diagnostic_validator.rb (148 LoC) and
# validator_warnings.rb (113 LoC). Design generalizes — PC-3 (driver)
# and PC-4 (fixed-point of meta_subclass itself) should reuse this
# pattern with different RubyClass rows.
