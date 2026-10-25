require_relative "../naming"
require_relative "errors"
require_relative "query_interpreter"
require_relative "refusal_wording"

module Hecks
  module Runtime
    # One command sent once per row a declared query answers: what a `for_each` policy and a
    # bulk run (ADR 0125) share. It reads the rows, says which key of the command addresses a
    # row, and records one row's delivery or refusal; who sends the command is the caller's.
    class RowSweep
      # @param registry [Runtime::Registry] the booted registry the query and command resolve in
      def initialize(registry)
        @registry = registry
      end

      # Runs a declared query and answers its rows.
      #
      # @param domain [String] the domain the query's aggregate belongs to
      # @param aggregate [Bluebook::Aggregate] the aggregate declaring the query
      # @param query_name [String] the query's name
      # @param args [Hash{Symbol => Object}] the query's arguments
      # @return [Array<Hash{Symbol => Object}>] each row's state with `:id` merged in
      def rows(domain, aggregate, query_name, args)
        Array(QueryInterpreter.new(@registry).call(domain, aggregate, query_name, args))
      end

      # The loaded aggregate a query belongs to.
      #
      # @param domain [String] the domain the aggregate belongs to
      # @param aggregate_name [String] the aggregate's name
      # @param verb [String] the spelling a refusal names, such as the policy's `for_each`
      # @return [Bluebook::Aggregate] the aggregate
      # @raise [Runtime::UnknownVerb] if the domain or aggregate is not loaded
      def query_aggregate(domain, aggregate_name, verb:)
        bluebook = @registry.bluebook(domain) ||
                   raise(UnknownVerb, RefusalWording.render_site("UnknownVerb", "no_domain", domain: domain, verb: verb))
        bluebook.aggregate(aggregate_name) ||
          raise(UnknownVerb, RefusalWording.render_site("UnknownVerb", "no_aggregate",
                                                        domain: domain, aggregate: aggregate_name))
      end

      # Resolves `target` back to its declared command and asks it how a row of `aggregate_name`
      # addresses it. Raises rather than guessing: an unaddressable target is an authoring mistake.
      #
      # @param target [String] the command's verb, `"Domain::Aggregate.Command"`
      # @param aggregate_name [String] the aggregate whose rows are swept
      # @param label [String] how a refusal names `target`
      # @return [Symbol] the argument a row's id fills
      # @raise [Runtime::UnknownVerb] if `target` names no declared command
      # @raise [ArgumentError] if the command cannot be addressed by a row of `aggregate_name`
      def addressing_key_for(target, aggregate_name, label: "the target")
        key = target_command(target, label: label).addressing_key_for(aggregate_name)
        return key if key

        raise ArgumentError,
              "#{target} cannot be addressed by a row of #{aggregate_name} — it declares no self-reference to " \
              "#{aggregate_name} and no reference-typed attribute targeting it"
      end

      # The declared command `target` names.
      #
      # @param target [String] the command's verb, `"Domain::Aggregate.Command"`
      # @param label [String] how a refusal names `target`
      # @return [Bluebook::Command] the command
      # @raise [Runtime::UnknownVerb] if `target` names no declared command
      def target_command(target, label: "the target")
        domain, aggregate_name, command_name = Naming.split_verb(target)
        command = @registry.bluebook(domain)&.aggregate(aggregate_name)&.command(command_name)
        command or raise UnknownVerb, "#{label} #{target.inspect} does not resolve to a declared command"
      end

      # Sends one row and records how it went: `delivered: true`, or the refusal's message.
      #
      # @param record [Hash{Symbol => Object}] the row's record so far, such as `{ for_row: id }`
      # @yield sends the command for this row
      # @return [Hash{Symbol => Object}] `record` with `delivered:` and, when refused, `reason:`
      def deliver(record)
        yield
        record.merge(delivered: true)
      rescue *DOMAIN_REFUSALS => e
        record.merge(delivered: false, reason: e.message)
      end
    end
  end
end
