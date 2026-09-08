# GENERATED — projected from the language's own Policy aggregate.
# DO NOT EDIT: the holding half is rendered, and Behaviour::Policy
# is where anything hand-written belongs.
require_relative "behaviour/policy"

module Hecks
  module Bluebook
    class Policy
      include Hecks::IR
      include Behaviour::Policy

      emits_ir(
        name:            :name,
        on_event:        :on_event,
        trigger_command: :trigger_command,
        target_domain:   :target_domain,
        where:           :where,
        for_each:        :for_each,
        with_spec:       -> { with_spec.map { |key, value| [key.to_s, Bluebook.render_value(value)] } },
        where_ast:       -> { where && Expression::AstJson.emit_predicate(where) }
      )

      attr_reader :name, :on_event, :trigger_command, :target_domain, :where, :for_each, :with_spec

      # AGGREGATE, DECLARED AND DELIBERATELY OFF THE WIRE
      # the wire format is a pinned contract, and it does not carry
      # where a policy was written before the builder hoisted it
      attr_accessor :aggregate

      def initialize(name:, on_event: nil, trigger_command: nil, target_domain: nil, where: nil, for_each: nil, with_spec: [], aggregate: nil)
        @name = name.to_s
        @on_event = on_event
        @trigger_command = trigger_command
        @target_domain = target_domain
        @where = where
        @for_each = for_each
        @with_spec = with_spec
        @aggregate = aggregate&.to_s
      end
    end
  end
end
