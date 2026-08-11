# Hecksagain::Bluebook
#
# Everything a .bluebook file becomes on its way to running: the expression
# language (expression/), the typed IR (ir/), the assembly that turns
# declarations back into that graph (assembly.rb + assembly/), the authoring
# DSL (dsl/), and the meta-validator that judges a chapter against the
# language's own grammar (meta_validator.rb + meta_validator/).
#
# The require order below preserves the boot order the flat list in
# lib/hecksagain.rb used to spell: expression and IR first (pure
# declarations), assembly's collaborators before its face, the DSL before
# the meta-validator that its builders call at build time.

module Hecksagain
  module Bluebook
  end
end

# What the chapter's own files lean on at class-body level (`extend
# Construct`, the assembly's QuerySpecification marks) — required here
# because those files' contents are frozen and cannot say so themselves.
require_relative "construct"
require_relative "literal"
require_relative "query_specification"

require_relative "bluebook/expression"
require_relative "bluebook/ir"

require_relative "bluebook/assembly/contract"
require_relative "bluebook/assembly/contracts"
require_relative "bluebook/assembly/specializer"
require_relative "bluebook/assembly/build"
require_relative "bluebook/assembly/marks"
require_relative "bluebook/assembly/aggregate_assembly"
require_relative "bluebook/assembly"

require_relative "bluebook/project_loader"

require_relative "bluebook/dsl"
require_relative "bluebook/pattern_subset"

require_relative "bluebook/meta_validator"
require_relative "bluebook/meta_validator/plan"
require_relative "bluebook/meta_validator/readings"
require_relative "bluebook/meta_validator/judge"
require_relative "bluebook/meta_validator/shapes"
require_relative "bluebook/meta_validator/reconstruction"
require_relative "bluebook/meta_validator/world_judge"
