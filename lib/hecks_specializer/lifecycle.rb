# lib/hecks_specializer/lifecycle.rb
#
# Hecks::Specializer::Lifecycle — emits hecks_life/src/lifecycle_validator.rs.
#
# Thin subclass of DiagnosticValidator. Uses report_kind=flat_with_strict
# (vs duplicate_policy's flat). Exercises 7 helpers including an empty-body
# stub (_force_command_use) which the base class emits inline.

require_relative "diagnostic_validator"

module Hecks
  module Specializer
    class Lifecycle < DiagnosticValidator
      SHAPE = REPO_ROOT.join("hecks_conception/capabilities/lifecycle_validator_shape/fixtures/lifecycle_validator_shape.fixtures")
      TARGET_RS = REPO_ROOT.join("hecks_life/src/lifecycle_validator.rs")
    end

    register :lifecycle, Lifecycle
  end
end
