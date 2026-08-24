require_relative "traits"

module Hecks
  module Bluebook
    module Behaviour
      # WHAT ONE PORT OPERATION DOES.
      module PortOperation
        include Indexed

        # An operation declares no reference of its own — the OWNER is
        # what it acts for, and `identity_attribute` is how that is found.
        def references = nil

        def identity_attribute(owner_name)
          @attributes.find { |attribute| attribute.reference? && attribute.type.target_name == owner_name.to_s }
        end
      end

      # WHAT A PORT DOES — one finder over its declared operations.
      module DomainPort
        def operation(named) = @operations.find { |op| op.hecks_name == named.to_s }
      end
    end
  end
end
