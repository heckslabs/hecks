require "json"
require "delegate"
require_relative "../../ports/projection"
require_relative "../../runtime/read_model_interpreter"

module Hecks
  module Fuzzing
    module ProjectionAgreement
      # Compares, for one booted registry, each rooted read model's answer through the
      # projection with the in-process loop's answer over the authoritative records alone.
      class Comparison
        # What one comparison found: each disagreement, and how many asks were answered both ways.
        Outcome = Struct.new(:offenders, :compared)

        # The registry as the loop sees it with every projection unbound: each read goes to the
        # authoritative repository, so no adapter's own read-model path is taken.
        class Authoritative < SimpleDelegator
          # @param domain [String, Symbol] the aggregate's domain
          # @param aggregate [Bluebook::Aggregate] the aggregate to read
          # @return [Ports::Persistence::AppendOnly] the authoritative repository
          def read_repository(domain, aggregate) = __getobj__.repository(domain, aggregate)
        end

        # @param registry [Runtime::Registry] a booted registry with its projections bound
        def initialize(registry)
          @registry = registry
          @through_projection = Runtime::ReadModelInterpreter.new(registry)
          @through_loop = Runtime::ReadModelInterpreter.new(Authoritative.new(registry))
          @compared = 0
        end

        # Catches every projection up, then lists each answer the two paths disagree on.
        #
        # @return [Outcome] `offenders`, one message per disagreement or per projection still
        #   stale after catch-up (empty when every rooted read model agrees), and `compared`
        def outcome
          catch_up!
          offenders = rooted_models.flat_map { |domain, model| model_offenders(domain, model) }
          Outcome.new(offenders, @compared)
        end

        private

        def catch_up!
          projected_aggregates.each do |domain, aggregate|
            Ports::Projection.worker(@registry, domain, aggregate, policy: :strict).catch_up!
          end
        end

        def projected_aggregates
          @registry.bluebooks.flat_map do |domain, bluebook|
            bluebook.aggregates.filter_map { |aggregate| [domain, aggregate] if projected?(domain, aggregate) }
          end
        end

        def projected?(domain, aggregate) = Ports::Projection.binds_for(@registry, domain, aggregate).any?

        # Every rooted read model whose root aggregate is projected, with its domain.
        def rooted_models
          @registry.bluebooks.flat_map do |domain, bluebook|
            bluebook.read_models.filter_map do |model|
              root = model.reference_target && bluebook.aggregate(model.reference_target)
              [domain, model] if root && projected?(domain, root)
            end
          end
        end

        # A stale projection is a finding of its own: comparing it would test the loop against
        # itself, since `read_repository` falls back to the authoritative store.
        def model_offenders(domain, model)
          root = @registry.bluebook(domain).aggregate(model.reference_target)
          if stale?(domain, root)
            return ["#{domain}.#{model.query_name}: #{root.name}'s projection is not current after catch-up"]
          end

          @registry.repository(domain, root).all.filter_map { |record| disagreement(domain, model, record.id.to_s) }
        end

        def stale?(domain, aggregate)
          @registry.read_repository(domain, aggregate).equal?(@registry.repository(domain, aggregate))
        end

        def disagreement(domain, model, id)
          @compared += 1
          args = { model.reference_name => id }
          projected = answer { @through_projection.call(domain, model, args) }
          looped = answer { @through_loop.call(domain, model, args) }
          return if projected == looped

          "#{domain}.#{model.query_name}(#{id}): the projection answered #{JSON.generate(projected)}, " \
            "the loop answered #{JSON.generate(looped)}"
        end

        # The answer as plain data, or the refusal it raised, so a path that refuses where the
        # other answers is a disagreement too.
        def answer
          JSON.parse(JSON.generate(yield))
        rescue StandardError => e
          { "refused" => "#{e.class}: #{e.message}" }
        end
      end
    end
  end
end
