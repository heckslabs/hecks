# Hecksagain::Bluebook
#
# Everything a .bluebook file becomes on its way to running: the expression
# language (expression/), the model itself (the chapter class plus
# everything it declares), the assembly that turns
# declarations back into that graph (assembly.rb + assembly/), the authoring
# DSL (dsl/), and the meta-validator that judges a chapter against the
# language's own grammar (meta_validator.rb + meta_validator/).
#
# The require order below preserves the boot order the flat list in
# lib/hecksagain.rb used to spell: expression and IR first (pure
# declarations), assembly's collaborators before its face, the DSL before
# the meta-validator that its builders call at build time.

module Hecksagain
  # Declared as a CLASS, not a module — `Hecksagain::Bluebook` IS a
  # chapter (bluebook/chapter.rb carries its body). Everything a chapter
  # declares nests under it, as do the ways to build one (`DSL`) and to
  # judge one (`MetaValidator`). Reopening this anywhere must say `class`.
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
# THE MODEL ITSELF — the chapter class's own body first, then everything
# a chapter declares. Order matters only for reading: each is a bag of
# declarations with no load-time cross-references.
require_relative "bluebook/chapter"
require_relative "bluebook/reference"
require_relative "bluebook/attribute"
require_relative "bluebook/value_object"
require_relative "bluebook/command"
require_relative "bluebook/lifecycle"
require_relative "bluebook/query"
require_relative "bluebook/read_model"
require_relative "bluebook/entity"
require_relative "bluebook/domain_port"
require_relative "bluebook/policy"
require_relative "bluebook/process_manager"
require_relative "bluebook/aggregate"
require_relative "bluebook/hexagon"
require_relative "bluebook/translation"

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
require_relative "bluebook/meta_validator/port_judge"
require_relative "bluebook/meta_validator/adapter_judge"
require_relative "bluebook/meta_validator/translation_judge"
require_relative "bluebook/meta_validator/syntax_boot"
