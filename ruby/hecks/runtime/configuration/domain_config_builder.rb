# Hecks::Configuration::DomainConfigBuilder
#
# DSL helper for domain block — collects listens_to/sends_to declarations.
# Created internally by Configuration#domain when a block is given.
#
#   domain "orders_domain" do
#     listens_to "inventory_domain"
#     sends_to "notifications_domain"
#   end
#
module Hecks
  class Configuration
    # Hecks::Configuration::DomainConfigBuilder
    #
    # DSL helper for domain configuration blocks collecting listens_to and sends_to declarations.
    #
    class DomainConfigBuilder
      attr_reader :listens, :sends

      def initialize
        @listens = []
        @sends = []
      end

      def listens_to(source)
        @listens << source
      end

      def sends_to(target)
        @sends << target
      end

      def extend(target, *args, **kwargs)
        if target.is_a?(String) || target.is_a?(Module)
          listens_to(target)
        else
          sends_to(target.to_s)
        end
      end
    end
  end
end
