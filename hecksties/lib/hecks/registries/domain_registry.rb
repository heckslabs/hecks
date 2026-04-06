# Hecks::DomainRegistryMethods
#
# Domain caching, load strategy, and last_domain tracking.
# Extracted from the Hecks module.
#
module Hecks
  module DomainRegistryMethods
    def loaded_domains
      @loaded_domains ||= Registry.new
    end

    def domain_objects
      @domain_objects ||= Registry.new
    end

    def last_domain
      @last_domain
    end

    def last_domain=(domain)
      @last_domain = domain
    end

    def last_bluebook
      @last_bluebook
    end

    def last_bluebook=(bluebook)
      @last_bluebook = bluebook
    end

    def last_hecksagon
      @last_hecksagon
    end

    def last_hecksagon=(hecksagon)
      @last_hecksagon = hecksagon
    end

    def load_strategy
      @load_strategy ||= :memory
    end

    def load_strategy=(strategy)
      @load_strategy = strategy
    end
  end
end
