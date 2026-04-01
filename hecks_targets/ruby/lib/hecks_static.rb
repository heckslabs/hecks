# = HecksStatic
#
# Standalone domain generator for Hecks. Produces a complete, self-contained
# Ruby project with zero runtime dependency on the hecks gem. The output
# includes an inlined runtime, HTTP server with UI, and all domain code.
#
# == Usage
#
#   require "hecks_static"
#   domain = Hecks.domain("Pizzas") { ... }
#   HecksStatic::GemGenerator.new(domain).generate
#
#   # Or via CLI:
#   hecks build --standalone
#
require_relative "hecks_static/generators/runtime_writer"
require_relative "hecks_static/generators/entry_point_generator"
require_relative "hecks_static/generators/server_generator"
require_relative "hecks_static/generators/ui_generator"
require_relative "hecks_static/generators/gem_generator"
