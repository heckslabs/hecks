# = GoHecks
#
# Go domain generator for Hecks. Produces a complete Go project from
# the same domain IR the Ruby generators read. Same DSL, Go output.
#
# == Usage
#
#   require "go_hecks"
#   domain = Hecks.domain("Pizzas") { ... }
#   GoHecks::ProjectGenerator.new(domain).generate
#
#   # Or via CLI:
#   hecks build --target go
#
require_relative "go_hecks/go_utils"
require_relative "go_hecks/generators/aggregate_generator"
require_relative "go_hecks/generators/value_object_generator"
require_relative "go_hecks/generators/command_generator"
require_relative "go_hecks/generators/event_generator"
require_relative "go_hecks/generators/port_generator"
require_relative "go_hecks/generators/memory_adapter_generator"
require_relative "go_hecks/generators/errors_generator"
require_relative "go_hecks/generators/lifecycle_generator"
require_relative "go_hecks/generators/query_generator"
require_relative "go_hecks/generators/specification_generator"
require_relative "go_hecks/generators/policy_generator"
require_relative "go_hecks/generators/view_generator"
require_relative "go_hecks/generators/runtime_generator"
require_relative "go_hecks/generators/application_generator"
require_relative "go_hecks/generators/renderer_generator"
require_relative "go_hecks/generators/server_generator"
require_relative "go_hecks/generators/show_template"
require_relative "go_hecks/generators/form_template"
require_relative "go_hecks/generators/index_template"
require_relative "go_hecks/generators/project_generator"
