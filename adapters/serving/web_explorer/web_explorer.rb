# HecksWebExplorer
#
# Domain web explorer extension for Hecks. Provides an HTML UI for
# browsing aggregates, executing commands, viewing events, switching
# roles and adapters. Renders ERB templates from the views/ directory.
#
# Works in all three modes:
# - Dynamic: gem "hecks_web_explorer" auto-wires at boot
# - Static: hecks_static bakes the views into the generated project
# - Go: go_hecks translates ERB to Go html/template
#
# Future gem: hecks_web_explorer
#
#   # Dynamic mode:
#   gem "hecks_web_explorer"
#   app = Hecks.boot(__dir__)
#   PizzasDomain.serve(port: 9292)  # includes web explorer UI
#
require "erb"

Hecks.describe_extension(:web_explorer,
  description: "Domain web explorer UI",
  adapter_type: :driving,
  config: {},
  wires_to: :http)

Hecks.register_extension(:web_explorer) do |domain_mod, domain, runtime|
  views_dir = File.expand_path("web_explorer/views", __dir__)
  domain_mod.instance_variable_set(:@_web_explorer_views, views_dir)
  domain_mod.instance_variable_set(:@_web_explorer_domain, domain)

  domain_mod.define_singleton_method(:web_explorer_views) { @_web_explorer_views }
  domain_mod.define_singleton_method(:web_explorer_domain) { @_web_explorer_domain }
end
