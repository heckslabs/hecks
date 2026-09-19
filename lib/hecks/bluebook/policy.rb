# Generated — projected from the language's own Policy aggregate.
# Do not edit: the holding half is rendered, and Behaviour::Policy
# is where anything hand-written belongs.
require_relative "behaviour/policy"

module Hecks
  module Bluebook
    class Policy
      include Hecks::IR
      include Behaviour::Policy

      emits_ir(
        name:               :name,
        on_event:           :on_event,
        trigger_command:    :trigger_command,
        target_domain:      :target_domain,
        expect_undelivered: :expect_undelivered,
        where:              :where,
        for_each:           :for_each,
        with_spec:          -> { with_spec.map { |key, value| [key.to_s, Bluebook.render_value(value)] } },
        where_ast:          -> { where_ast }
      )

      attr_reader :name, :on_event, :trigger_command, :target_domain, :expect_undelivered, :where, :for_each, :with_spec

      # Aggregate, declared and deliberately off the wire
      # the wire format is a pinned contract, and it does not carry
      # where a policy was written before the builder hoisted it
      attr_accessor :aggregate

      def initialize(name:, on_event: nil, trigger_command: nil, target_domain: nil, expect_undelivered: false, where: nil, for_each: nil, with_spec: [], aggregate: nil)
        @name = name.to_s
        @on_event = on_event
        @trigger_command = trigger_command
        @target_domain = target_domain
        @expect_undelivered = expect_undelivered.to_s == "true"
        @where = where
        @for_each = for_each
        @with_spec = with_spec
        @aggregate = aggregate&.to_s
      end
    end
  end
end
