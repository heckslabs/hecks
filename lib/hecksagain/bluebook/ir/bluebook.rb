module Hecksagain
  module Bluebook
    module IR
      class Bluebook
        attr_reader :name, :vision, :aggregates, :policies, :process_managers,
                    :classification

        def initialize(name:, vision: nil, aggregates: [], policies: [],
                       process_managers: [], classification: nil)
          @policies         = policies
          @process_managers = process_managers
          @name       = name.to_s
          @vision     = vision
          @aggregates = aggregates
          @classification = classification&.to_s
        end

        def aggregate(named) = @aggregates.find { |a| a.name == named.to_s }

        def verbs
          @aggregates.flat_map do |agg|
            agg.commands.map { |cmd| "#{@name}::#{agg.name}.#{cmd.name}" }
          end
        end

        def to_h
          {
            name:             @name,
            vision:           @vision,
            classification:   @classification,
            aggregates:       @aggregates.map(&:to_h),
            policies:         @policies.map(&:to_h),
            process_managers: @process_managers.map(&:to_h),
            canonical_form:   Expression::CanonicalForm.table
          }
        end
      end
    end
  end
end
