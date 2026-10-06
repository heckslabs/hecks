require_relative "../errors"
require_relative "../refusal_wording"

module Hecks
  module Runtime
    class Dispatcher
      # Answers declared queries: aggregate queries, entity queries and read models. Mixed into
      # {Dispatcher}, which owns the interpreters and the verb parsing these read.
      module Queries
        # Answers a declared query: an aggregate query, an entity query, or a read model.
        #
        # `"Domain.ReadModel"` (no `::`) is a read model; `"Domain::Aggregate.Query"` and
        # `"Domain::Aggregate.Entity.Query"` are aggregate and entity queries.
        #
        # @param verb [String, Symbol] the query's verb, in one of the three shapes above
        # @param args [Hash{Symbol => Object}] the query's declared arguments
        # @return [Array<Hash>] one Hash per matching record or element; a read model returns a
        #   one-element Array holding a Hash of head name to projected rows
        # @raise [Runtime::UnknownVerb] if the verb is malformed or names something undeclared
        # @raise [Runtime::NotFound] if a read model's root reference names no record
        # @raise [Runtime::TypeMismatch] if an argument cannot be coerced to its declared type
        def query(verb, **args)
          domain, query_name = verb.to_s.split(".", 2)
          return read_model_query(domain, query_name, verb, args) if query_name && !domain.include?("::")

          domain, aggregate_name, query_name = parse(verb)
          aggregate = resolve_aggregate(domain, aggregate_name, verb)

          @queries.call(domain, aggregate, query_name, args)
        end

        # Answers an aggregate or entity query through the reference interpreter alone.
        #
        # Never answered by the bound adapter's native hook; the fuzzer's query oracle diffs it
        # against `#query`. Read models have no reference twin.
        #
        # @param verb [String] `"Domain::Aggregate.Query"` or `"Domain::Aggregate.Entity.Query"`
        # @param args [Hash{Symbol => Object}] the query's declared arguments
        # @return [Array<Hash>] one Hash per matching record or element
        # @raise [Runtime::UnknownVerb] if the verb is malformed or names something undeclared
        # @raise [Runtime::TypeMismatch] if an argument cannot be coerced to its declared type
        def reference_query(verb, **args)
          domain, aggregate_name, query_name = parse(verb)
          aggregate = resolve_aggregate(domain, aggregate_name, verb)

          @queries.reference_call(domain, aggregate, query_name, args)
        end

        private

        def read_model_query(domain, query_name, verb, args)
          bluebook = @registry.bluebook(domain) ||
                     raise(UnknownVerb, RefusalWording.render_site("UnknownVerb", "no_domain", domain: domain, verb: verb))
          model = bluebook.read_model(query_name) ||
                  raise(UnknownVerb, RefusalWording.render_site("UnknownVerb", "no_read_model",
                                                                domain: domain, query: query_name))
          @read_models.call(domain, model, args)
        end
      end
    end
  end
end
