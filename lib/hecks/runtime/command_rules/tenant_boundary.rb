require_relative "../errors"
require_relative "../refusal_wording"
require_relative "../../rendering"
require_relative "../../ports/query/in_memory"

module Hecks
  module Runtime
    class CommandRules
      # Refuses a write whose record and referenced record disagree about their tenant. One
      # instance covers one record's state, so every reference it holds is checked against the
      # same tenant.
      class TenantBoundary
        # @param rules [Runtime::CommandRules] the rules engine, for its registry and key rendering
        # @param domain [String, Symbol] the domain the record belongs to
        # @param construct [Bluebook::Aggregate, Bluebook::Entity] the record's declaring construct
        # @param state [Hash{Symbol => Object}] the record's settled state
        # @param own_field [Symbol, nil] the record's tenant field, nil when it declares none
        def initialize(rules, domain, construct, state, own_field)
          @rules     = rules
          @domain    = domain
          @construct = construct
          @state     = state
          @own_field = own_field
        end

        # Checks every record `held` names through `attribute` against the record's own tenant.
        #
        # @param attribute [Bluebook::Attribute] the reference-typed attribute
        # @param target [Bluebook::Aggregate] the aggregate the reference points at
        # @param held [Object, Array<Object>] the reference value (or values, for a list)
        # @param target_field [Symbol, nil] the target's tenant field, nil when it declares none
        # @return [void]
        # @raise [Runtime::Unauthorized] a referenced record belongs to another tenant
        def enforce(attribute, target, held, target_field)
          return unless @own_field && @state.key?(@own_field) && target_field

          own_tenant = Ports::Query::InMemory.comparable(@state[@own_field])
          (attribute.list? ? Array(held) : [held]).each do |value|
            record = referenced_record(target, value)
            refuse_crossing(attribute, target, target_field, record) if crosses?(record, target_field, own_tenant)
          end
        end

        private

        # Whether the record carries a tenant that differs from `own_tenant`.
        def crosses?(record, target_field, own_tenant)
          record&.state&.key?(target_field) &&
            Ports::Query::InMemory.comparable(record.state[target_field]) != own_tenant
        end

        def referenced_record(target, value)
          key = @rules.reference_key(value)
          @rules.registry.repository(@domain, target).find(key) unless key.empty?
        end

        def refuse_crossing(attribute, target, target_field, record)
          raise Unauthorized,
                RefusalWording.render_site("Unauthorized", "cross_tenant_reference",
                                           aggregate: @construct.hecks_name, field: @own_field,
                                           tenant: Rendering.describe(@state[@own_field]),
                                           attribute: attribute.name, target: target.name,
                                           target_field: target_field,
                                           other: Rendering.describe(record.state[target_field]))
        end
      end
    end
  end
end
