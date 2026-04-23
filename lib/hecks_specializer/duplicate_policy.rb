# lib/hecks_specializer/duplicate_policy.rb
#
# Hecks::Specializer::DuplicatePolicy — emits
# hecks_life/src/duplicate_policy_validator.rs.
#
# Thin subclass of DiagnosticValidator. All emission logic lives in
# the base class; this file just points at the shape + target.

require_relative "diagnostic_validator"

module Hecks
  module Specializer
    class DuplicatePolicy < DiagnosticValidator
      SHAPE = REPO_ROOT.join("hecks_conception/capabilities/duplicate_policy_validator_shape/fixtures/duplicate_policy_validator_shape.fixtures")
      TARGET_RS = REPO_ROOT.join("hecks_life/src/duplicate_policy_validator.rs")
    end

    register :duplicate_policy, DuplicatePolicy
  end
end
