# Everything a .bluebook file becomes on its way to running: expression language, model,
# assembly, authoring DSL and meta-validator.

module Hecks
  # `Hecks::Bluebook` is a class defined in bluebook/chapter.rb; reopen it with `class`.
  module Bluebook
  end
end

# Required here because the chapter's frozen files lean on these at class-body level.
# Load order: expression and IR first, assembly's collaborators before its face, DSL last.
require_relative "construct"
require_relative "literal"
require_relative "query_specification"

require_relative "bluebook/expression"
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
