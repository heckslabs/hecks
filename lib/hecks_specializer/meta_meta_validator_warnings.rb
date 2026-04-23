# lib/hecks_specializer/meta_meta_validator_warnings.rb
#
# Hecks::Specializer::MetaMetaValidatorWarnings — Phase C PC-4 companion.
#
# Regenerates lib/hecks_specializer/meta_validator_warnings.rb (the thin
# subclass of MetaDiagnosticValidator that targets validator_warnings.rb)
# from RubyClass + RubyMethod rows in diagnostic_validator_meta_shape.
# Pairs with MetaMetaDiagnosticValidator to close the fixed point: both
# meta-specializer files are now bluebook-driven.
#
# Thin subclass — overrides target_class_name to pick the
# MetaValidatorWarnings row; all emission logic is inherited.

require_relative "meta_diagnostic_validator"

module Hecks
  module Specializer
    class MetaMetaValidatorWarnings < MetaDiagnosticValidator
      TARGET_RS = REPO_ROOT.join("lib/hecks_specializer/meta_validator_warnings.rb")
      def self.target_class_name
        "MetaValidatorWarnings"
      end
    end

    register :meta_meta_validator_warnings, MetaMetaValidatorWarnings
  end
end
