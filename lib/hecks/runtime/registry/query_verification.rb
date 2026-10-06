module Hecks
  module Runtime
    class Registry
      # Holds every declared query to exactly one answer path, and a bound query to an adapter that
      # implements it. Mixed into {Verification}.
      module QueryVerification
        private

        # A query has exactly one answer path. It is derivable when the bluebook says which of the
        # aggregate's own records it wants (a where, order_by, limit or offset, or no arguments at
        # all: the plain list) and returns no value object of its own; it is bound when it
        # `returns` a value object and the hecksagon names the port whose adapter answers it. None
        # of the two is "no answer path"; both is "two answer paths". A bound query also needs an
        # adapter behind its port that implements it, found here so it fails at boot rather than
        # on the first ask.
        def refuse_unanswerable_queries!
          @declared.bluebooks.each_value do |chapter|
            chapter.aggregates.each do |aggregate|
              refuse_misbound_queries!(chapter, aggregate)

              aggregate.queries.each { |query| refuse_answer_paths!(chapter, aggregate, query) }
              aggregate.entities.each do |entity|
                entity.queries.each { |query| refuse_entity_answer_path!(chapter, aggregate, entity, query) }
              end
            end
          end
        end

        # Counts the query's answer paths (the bindings, plus the derived answer when it exists)
        # and refuses any count but one, then checks a bound query's shape and adapter.
        def refuse_answer_paths!(chapter, aggregate, query)
          where  = "#{chapter.name}::#{aggregate.hecks_name}.#{query.hecks_name}"
          ports  = aggregate.query_bindings(query.hecks_name)
          paths  = ports.size + (derivable?(query) ? 1 : 0)

          if paths > 1
            raise WiringError, "#{where} has two answer paths: #{answer_path_names(query, ports)} — " \
                               "a query is answered from records or from outside, not both"
          end
          return check_bound_query!(chapter, aggregate, query, ports.first) if ports.any?
          return if paths == 1

          raise WiringError, no_answer_path_message(chapter, aggregate, query, where)
        end

        # A query that returns nothing and says something about which records it wants, or wants
        # all of them. One that takes arguments but filters, orders and bounds nothing reads none
        # of them, so it derives no answer.
        def derivable?(query)
          return false if query.returns

          filters_records?(query) || query.attributes.empty?
        end

        def answer_path_names(query, ports)
          names = ports.map { |port| "the #{port.name} port" }
          names.unshift("its records") if derivable?(query)
          names.join(" and ")
        end

        def no_answer_path_message(chapter, aggregate, query, where)
          if query.returns
            "#{where} has no answer path: it returns #{query.returns}, which only an adapter can " \
              "answer, and no hecksagon port binds it. Bind it: `#{chapter.name}::#{aggregate.hecks_name}" \
              ".port \"Port\" do answers_query \"#{query.hecks_name}\" end`."
          else
            "#{where} has no answer path: it declares no where and returns nothing, and no hecksagon " \
              "binds it — its arguments (#{query.attributes.map(&:name).join(", ")}) select nothing. " \
              "Add a where, or declare what it returns and bind it in the hecksagon."
          end
        end

        # Checks what a binding needs to be answerable: a returned value object the aggregate
        # declares, and one adapter behind the port that implements the query's method.
        def check_bound_query!(chapter, aggregate, query, port)
          where = "#{chapter.name}::#{aggregate.hecks_name}.#{query.hecks_name}"
          refuse_unanswerable_binding!(where, port, query)
          refuse_authorized_binding!(where, port, query)
          unless Value.value_object_for(aggregate, query.returns_name)
            raise WiringError, "#{where} returns #{query.returns_name}, but #{aggregate.hecks_name} " \
                               "declares no such value object"
          end

          klass = AdapterLookup.adapter_class(self, port.name, asked: where)
          AdapterLookup.check_answers!(klass, port.name, Naming.snake(query.hecks_name), query, asked: where)
        end

        # A bound query returns a value object and filters no stored records.
        def refuse_unanswerable_binding!(where, port, query)
          unless query.returns
            raise WiringError, "#{where} is bound to the #{port.name} port but returns nothing — " \
                               "declare the value object its answer takes with `returns`"
          end
          return unless filters_records?(query)

          raise WiringError, "#{where} has two answer paths: it is bound to the #{port.name} port but " \
                             "also declares where, order_by or limit over stored records"
        end

        def refuse_authorized_binding!(where, port, query)
          return unless query.authorization

          raise WiringError, "#{where} is bound to the #{port.name} port but declares authorize — " \
                             "an outside answer is never tenant-scoped or authorized, so drop the " \
                             "authorize or answer the query from records"
        end

        # An entity's query reads the elements of its aggregate's list, and nothing outside can
        # be bound to one, so declaring a value object to return leaves it no answer.
        def refuse_entity_answer_path!(chapter, aggregate, entity, query)
          where = "#{chapter.name}::#{aggregate.hecks_name}.#{entity.hecks_name}.#{query.hecks_name}"
          if query.returns
            raise WiringError, "#{where} has no answer path: it returns #{query.returns}, but " \
                               "only an aggregate's queries can be bound to a port"
          end
          return if derivable?(query)

          raise WiringError, "#{where} has no answer path: it declares no where and returns nothing — its " \
                             "arguments (#{query.attributes.map(&:name).join(", ")}) select nothing"
        end

        # Refuses a binding that names a query its aggregate does not declare, or names one twice
        # on a single port (the DSL already refuses that, so this guards a hand-built port).
        def refuse_misbound_queries!(chapter, aggregate)
          aggregate.ports.each do |port|
            names = port.answered_queries.map(&:name)
            names.each do |name|
              where = "#{chapter.name}::#{aggregate.hecks_name}.#{name}"
              unless aggregate.query(name)
                raise WiringError, "the #{port.name} port binds #{where}, which the aggregate does not declare"
              end
              raise WiringError, "#{where} has two answer paths: the #{port.name} port twice" if names.count(name) > 1
            end
          end
        end

        # A query that says anything about which stored records it wants.
        def filters_records?(query)
          !(query.wheres.empty? && query.order_by.nil? && query.limit.nil? && query.offset.nil?)
        end
      end
    end
  end
end
