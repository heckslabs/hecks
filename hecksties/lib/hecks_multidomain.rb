# = HecksMultidomain
#
# Multi-domain support for Hecks. Provides filtered event buses,
# cross-domain validation, event directionality, aggregate promotion,
# and cross-domain queries/views.
#
# Lazy-loaded by Boot when hecks_domains/ is detected.
#
#   require "hecks_multidomain"
#
module Hecks
  autoload :FilteredEventBus,  "hecks_multidomain/filtered_event_bus"
  autoload :CrossDomainQuery,  "hecks_multidomain/cross_domain_query"
  autoload :CrossDomainView,   "hecks_multidomain/cross_domain_view"

  # Hecks::MultiDomain
  #
  # Multi-domain support: filtered event buses, cross-domain validation, directionality, and queue wiring.
  #
  module MultiDomain
    autoload :Directionality, "hecks_multidomain/directionality"
    autoload :Validator,      "hecks_multidomain/validator"
    autoload :QueueWiring,    "hecks_multidomain/queue_wiring"
    autoload :Boot,           "hecks_multidomain/boot"
  end
end
