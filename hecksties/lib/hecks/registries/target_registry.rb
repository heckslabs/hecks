# Hecks::TargetRegistryMethods
#
# Registry for build targets. Each target (ruby, static, go, rails) registers
# a callable that receives a domain and options, and returns the build output.
#
#   Hecks.register_target(:go) { |domain, **opts| Hecks.build_go(domain, **opts) }
#   Hecks.target_registry[:go].call(domain)
#
module Hecks
  # Hecks::TargetRegistryMethods
  #
  # Registry for build targets (ruby, static, go, rails) extended onto the Hecks module.
  #
  module TargetRegistryMethods
    def target_registry
      @target_registry ||= Registry.new
    end

    def register_target(name, &builder)
      target_registry.register(name, builder)
    end
  end
end
