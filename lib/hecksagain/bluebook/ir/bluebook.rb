module Hecksagain
  module Bluebook
    module IR
      # A chapter — the top of the construct chain.
      #
      # It is a ROOT: nothing declares it, so `hecks_fqn` is just its name. That is
      # what `hecks_root` exists to say, and saying it here is what keeps
      # `hecks_fqn` refusing for every construct that is merely unstamped.
      class Bluebook
        include Construct

        attr_reader :name, :version, :vision, :aggregates, :policies, :process_managers,
                    :classification, :read_models

        def initialize(name:, version: nil, vision: nil, aggregates: [], policies: [],
                       process_managers: [], classification: nil, read_models: [])
          @policies         = policies
          @process_managers = process_managers
          @name       = name.to_s
          @hecks_name = @name
          @hecks_root = true
          @version    = version&.to_s
          @vision     = vision
          @aggregates = aggregates
          @read_models = read_models
          @classification = classification&.to_s
        end

        def aggregate(named) = @aggregates.find { |a| a.name == named.to_s }
        def read_model(named) = @read_models.find { |model| model.name == named.to_s || model.query_name == named.to_s }

        def verbs
          @aggregates.flat_map do |agg|
            agg.commands.map { |cmd| "#{@name}::#{agg.hecks_name}.#{cmd.hecks_name}" }
          end
        end

        def to_h
          {
            name:             @name,
            version:          @version,
            vision:           @vision,
            classification:   @classification,
            aggregates:       @aggregates.map(&:to_h),
            read_models:      @read_models.map(&:to_h),
            policies:         @policies.map(&:to_h),
            process_managers: @process_managers.map(&:to_h),
            canonical_form:   Expression::CanonicalForm.table
          }
        end
      end
    end
  end
end
