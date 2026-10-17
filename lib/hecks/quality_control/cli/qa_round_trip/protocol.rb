# frozen_string_literal: true

require_relative "rows"

module Hecks
  module QualityControlCli
    class QaRoundTrip
      # The benchmark's command language, which an implementation written without Hecks reads.
      #
      # A fuzzer step names its verb with the domain (`"Harbor::Wharf.Close"`), wraps each value
      # in `{ "value" => ... }`, and names an existing record by its identity field. A protocol
      # step names the verb `Aggregate.Command`, passes plain values, and names an existing record
      # by its aggregate's reference key (`"wharf"`), as a program's own API would.
      class Protocol
        # @param bluebook_ir [Hash] the domain's IR, as `Bluebook::Chapter#to_h` gives it
        def initialize(bluebook_ir)
          @aggregates = bluebook_ir[:aggregates].to_h { |aggregate| [aggregate[:name], aggregate] }
        end

        # Names the aggregates the protocol cannot express: each named by more than one field,
        # since one reference key cannot carry several values.
        #
        # @return [Array<String>] the aggregates with a composite identity; empty when none
        def composite_aggregates
          @aggregates.values.select { |aggregate| aggregate[:identified_by].size > 1 }.map { |a| a[:name] }
        end

        # Rewrites one fuzzer step as a protocol step.
        #
        # @param step [Hash] a `Fuzzing::SequenceGenerator` step: `"verb"` or `"query"`, and
        #   `"args"`
        # @return [Hash] `"command"` and `"args"`, or `"query"` and `"args"`
        def step(step)
          args = plain(step["args"] || {})
          return { "query" => local(step["query"]), "args" => args } if step["query"]

          path = local(step["verb"])
          { "command" => path, "args" => addressed(path, args) }
        end

        # The reference key a protocol step names `aggregate` by: its name in snake_case.
        #
        # @param aggregate [String] the aggregate's name, such as `"Wharf"`
        # @return [String] the key, such as `"wharf"`
        def self.reference_key(aggregate) = aggregate.gsub(/([a-z\d])([A-Z])/, '\1_\2').downcase

        private

        def local(verb) = verb.to_s.split("::", 2).last

        # An entity command, or a command that acts on its own aggregate, names the record by the
        # reference key instead of the identity field the fuzzer filled.
        def addressed(path, args)
          aggregate_name, *rest = path.split(".")
          aggregate = @aggregates.fetch(aggregate_name)
          return args unless rest.size == 2 || acts_on_itself?(aggregate, rest.first)

          head = aggregate[:identified_by].first.split(".").first
          return args unless args.key?(head)

          args.except(head).merge(self.class.reference_key(aggregate_name) => args[head])
        end

        def acts_on_itself?(aggregate, command_name)
          aggregate[:commands].any? { |command| command[:name] == command_name && command[:references] == aggregate[:name] }
        end

        def plain(value) = Rows.plain(value)
      end
    end
  end
end
