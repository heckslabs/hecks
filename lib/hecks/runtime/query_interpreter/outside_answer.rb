require_relative "../../naming"
require_relative "../adapter_lookup"
require_relative "../errors"
require_relative "../refusal_wording"
require_relative "../value"

module Hecks
  module Runtime
    class QueryInterpreter
      # A query the hecksagon binds to a port: answered by the adapter behind it, and the answer
      # checked against the value object the query `returns`. Mixed into {QueryInterpreter}.
      module OutsideAnswer
        private

        # Asks the port's adapter the question the hecksagon bound to this query, by the query's
        # snake-cased name and with its arguments as plain data. Each row of the answer is built as
        # the value object the query `returns`, so an answer that is not that shape is refused
        # before it enters the domain. The aggregate's records are never read.
        #
        # @return [Array<Hash>] the rows as the returned value object's fields, frozen
        # @raise [Runtime::WiringError] if no adapter answers the port or the adapter lacks the
        #   method
        # @raise [Runtime::TypeMismatch, Runtime::InvariantViolation, Runtime::UnknownArgument,
        #   Runtime::AbsentArgument] naming the query, if the answer is not its declared shape
        def answered_from_outside(aggregate, declared, args, port)
          asked = "#{aggregate.hecks_name}.#{declared.name}"
          refuse_offered_arguments!(declared, args, asked)
          adapter = AdapterLookup.call(@registry, port.name, asked: asked)
          method  = Naming.snake(declared.name)
          # The real adapter's class is what must answer; a fuzz replay's stand-in refuses instead.
          klass   = AdapterLookup.adapter_class(@registry, port.name, asked: asked)
          AdapterLookup.check_answers!(klass, port.name, method, declared, asked: asked)

          answer = adapter.public_send(method, **Value.materialize(args))
          Freezer.deep(shaped(aggregate, declared, answer, asked))
        end

        # Refuses arguments the adapter cannot be handed: a required one left out, or one the query
        # does not declare. The adapter is asked by keyword, so either would otherwise reach it as a
        # raw ArgumentError.
        #
        # @raise [Runtime::AbsentArgument] if a non-optional declared argument is missing
        # @raise [Runtime::UnknownArgument] if `args` names an argument the query does not declare
        def refuse_offered_arguments!(declared, args, asked)
          names   = declared.attributes.map { |attribute| attribute.name.to_sym }
          offered = args.keys.map(&:to_sym)
          unknown = (offered - names).sort
          unless unknown.empty?
            raise UnknownArgument, RefusalWording.render_site("UnknownArgument", "unknown_args",
                                                              command: asked, unknown: unknown, declared: names)
          end

          refuse_absent_offered!(declared, offered, names, asked)
        end

        def refuse_absent_offered!(declared, offered, names, asked)
          required = declared.attributes.reject(&:optional?).map { |attribute| attribute.name.to_sym }
          absent   = (required - offered).sort
          return if absent.empty?

          raise AbsentArgument, RefusalWording.render_site("AbsentArgument", "absent_args",
                                                           command: asked, absent: absent, declared: names)
        end

        # Builds the adapter's answer as the declared value object: one row, or a list of rows for
        # `returns list_of(...)`. A refusal keeps its class and gains the query's name.
        def shaped(aggregate, declared, answer, asked)
          value_object = Value.value_object_for(aggregate, declared.returns_name) or
            raise WiringError, "#{asked} returns #{declared.returns_name.inspect}, which the aggregate " \
                               "declares no value object for"
          offered = declared.returns_list? ? answer : [answer]
          unless offered.is_a?(Array) && offered.all?(Hash)
            raise TypeMismatch, "#{asked} answered outside the domain, but #{answer.class} is not " \
                                "#{declared.returns_list? ? "a list of" : "a"} #{value_object.hecks_name} row"
          end

          offered.map { |row| answered_row(value_object, row, aggregate, declared, asked) }
        end

        # One row of an outside answer, built and validated as the returned value object.
        def answered_row(value_object, row, aggregate, declared, asked)
          Value.build(value_object, row, aggregate).to_h
        rescue TypeMismatch, InvariantViolation, UnknownArgument, AbsentArgument => e
          raise e.class, "#{asked} answered outside the domain, but not as its #{declared.returns} — #{e.message}"
        end
      end
    end
  end
end
