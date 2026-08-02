module Hecksagain
  module Bluebook
    # The authoring surface — one builder per declaration kind, collecting
    # what a .bluebook file says into the IR. Builders call the
    # meta-validator at build time, not at load time, so their require
    # order here is the readable one.
    module DSL
    end
  end
end

# The query/read-model builders reach QuerySpecification at class-body
# level and cannot say so themselves (contents frozen) — the namespace
# file says it for them. The builders also build IR, at build time.
require_relative "../construct"
require_relative "../query_specification"
require_relative "ir"

require_relative "dsl/malformed"
require_relative "dsl/const_shim"
require_relative "dsl/attribute_collector"
require_relative "dsl/value_object_builder"
require_relative "dsl/command_builder"
require_relative "dsl/lifecycle_builder"
require_relative "dsl/query_builder"
require_relative "dsl/read_model_builder"
require_relative "dsl/entity_builder"
require_relative "dsl/policy_builder"
require_relative "dsl/process_manager_builder"
require_relative "dsl/aggregate_builder"
require_relative "dsl/bluebook_builder"
require_relative "dsl/binding_proxy"
require_relative "dsl/hecksagon_builder"
require_relative "dsl/port_builder"
require_relative "dsl/adapter_builder"
require_relative "dsl/world_builder"
require_relative "dsl/translation_builder"
