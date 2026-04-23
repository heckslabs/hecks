# lib/hecks_specializer/meta_validator_warnings.rb
#
# Hecks::Specializer::MetaValidatorWarnings — Phase C PC-2 extension.
#
# Second full Ruby class retirement. Emits lib/hecks_specializer/
# validator_warnings.rb from the ValidatorWarnings RubyClass row in the
# diagnostic_validator_meta_shape. Adds two features the base exercised
# for the first time:
#   - RubyConstant rows (SHAPE, TARGET_RS at class-body top)
#   - register_target_name ("validator_warnings")

require_relative "meta_diagnostic_validator"

module Hecks
  module Specializer
    class MetaValidatorWarnings < MetaDiagnosticValidator
      TARGET_RS = REPO_ROOT.join("lib/hecks_specializer/validator_warnings.rb")

      def self.target_class_name
        "ValidatorWarnings"
      end
    end

    register :meta_validator_warnings, MetaValidatorWarnings
  end
end
