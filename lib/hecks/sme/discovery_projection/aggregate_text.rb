require_relative "../../naming"

module Hecks
  module SME
    module DiscoveryProjection
      # The bluebook block of one accepted thing: an aggregate identified by a `ref`, its accepted
      # fields as attributes each held in a value object of its own name (an aggregate's attribute
      # is never a bare `String`), and its accepted actions as commands, each line headed by the
      # Point and the exchange it came from.
      module AggregateText
        module_function

        # @param name [String] the aggregate's name
        # @param point [Hash] the thing Point
        # @param fields [Array<Array(Hash, String)>] each field Point with its attribute name
        # @param actions [Array<Array(Hash, String, String)>] each action Point with its command
        #   and event
        # @return [Array<String>] the block's lines, indented for the bluebook body
        def lines(name, point, fields, actions)
          [DiscoveryProjection.cite(point), %(  aggregate "#{name}" do), "    identified_by :ref",
           "    attribute :ref, Ref", '    value_object("Ref") { attribute :value, String }'] +
            fields.flat_map { |field_point, attr| field_lines(field_point, attr) } +
            actions.flat_map { |action_point, command, event| command_lines(action_point, command, event) } +
            ["  end"]
        end

        # @api private
        def field_lines(point, name)
          type = Naming.pascal(name)
          ["    #{DiscoveryProjection.cite(point).strip}", "    attribute :#{name}, #{type}",
           %(    value_object("#{type}") { attribute :value, String })]
        end

        # @api private
        def command_lines(point, command, event)
          ["", "    #{DiscoveryProjection.cite(point).strip}", %(    command "#{command}" do),
           %(      role "Maintainer"), "      goal #{DiscoveryProjection.flat(point[:statement]).inspect}",
           "      attribute :ref, Ref", %(      emits "#{event}"), "    end"]
        end
      end
    end
  end
end
