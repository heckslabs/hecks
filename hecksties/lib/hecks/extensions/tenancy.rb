# HecksTenancy
#
# Multi-tenancy extension for Hecks domains. Wraps repositories with
# tenant-scoped proxies so each tenant sees isolated data. The tenant
# identity is set globally via +Hecks.tenant = "acme"+ and all subsequent
# repository operations are scoped to that tenant.
#
# Currently supports the +:column+ strategy (declared in the DSL with
# +tenancy :column+), which maintains separate in-memory repository
# instances keyed by tenant ID. Only activates when the domain has
# tenancy configured.
#
# Future gem: hecks_tenancy
#
#   # Gemfile
#   gem "cats_domain"
#   gem "hecks_tenancy"
#
#   # Console
#   Hecks.tenant = "acme"
#   Cat.create(name: "Whiskers")   # stored under acme
#   Hecks.tenant = "beta"
#   Cat.all                        # => [] (beta has no cats)
#
require_relative "tenancy_support/tenant_scoped_repository"

Hecks.describe_extension(:tenancy,
  description: "Multi-tenant column-scoped data isolation",
  adapter_type: :driven,
  config: { strategy: { default: :column, desc: "Tenancy strategy" } },
  wires_to: :repository)

# Register the tenancy extension. On boot:
# 1. Checks if the domain has tenancy configured (skips if not)
# 2. For each aggregate, wraps the existing repository with a
#    TenantScopedRepository proxy
# 3. Swaps the original adapter with the tenant-scoped proxy in the runtime
#
# @param domain_mod [Module] the domain module constant (e.g. CatsDomain)
# @param domain [Hecks::Domain] the parsed domain definition; must respond
#   to +tenancy+ returning a truthy value for the extension to activate
# @param runtime [Hecks::Runtime] the runtime instance whose adapters will be
#   wrapped with tenant-scoped proxies
Hecks.register_extension(:tenancy) do |domain_mod, domain, runtime|
  tenancy = domain.respond_to?(:tenancy) && domain.tenancy
  tenancy ||= Hecks.last_hecksagon&.tenancy
  next unless tenancy

  domain.aggregates.each do |agg|
    repo = runtime[agg.name]
    proxy = HecksTenancy::TenantScopedRepository.new(repo.class)
    runtime.swap_adapter(agg.name, proxy)
  end
end
