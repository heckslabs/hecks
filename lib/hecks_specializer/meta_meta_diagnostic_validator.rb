# lib/hecks_specializer/meta_meta_diagnostic_validator.rb
#
# Hecks::Specializer::MetaMetaDiagnosticValidator — Phase C PC-4.
#
# THE FUTAMURA FIXED POINT. This target regenerates the meta-specializer
# itself (meta_diagnostic_validator.rb) from RubyClass + RubyMethod +
# RubyConstant rows in diagnostic_validator_meta_shape.fixtures. When
# the golden test goes green, a specializer is emitting its own source
# byte-identical — the 2nd Futamura projection in closed form.
#
# Thin subclass — overrides target_class_name to pick the
# MetaDiagnosticValidator row; all emission logic is inherited.

require_relative "meta_diagnostic_validator"

module Hecks
  module Specializer
    class MetaMetaDiagnosticValidator < MetaDiagnosticValidator
      TARGET_RS = REPO_ROOT.join("lib/hecks_specializer/meta_diagnostic_validator.rb")
      def self.target_class_name
        "MetaDiagnosticValidator"
      end
    end

    register :meta_meta_diagnostic_validator, MetaMetaDiagnosticValidator
  end
end
