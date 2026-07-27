# Bluebook — one bounded context: a vision sentence and the aggregates inside
# it. This is the whole domain IR, and the thing every other target (Rust, SQL,
# tests, docs) is eventually a PROJECTION of.
#
# Ruby holds the semantics ; everything else is generated downstream. That
# inversion is the point of hecksagain — there is exactly one author.
#
#   Bluebook.new(name: "Pizzas", vision: "...", aggregates: [...])
module Hecksagain
  module Bluebook
    module IR
      class Bluebook
        attr_reader :name, :vision, :aggregates, :policies, :process_managers

        def initialize(name:, vision: nil, aggregates: [], policies: [],
                       process_managers: [])
          @policies         = policies
          @process_managers = process_managers
          @name       = name.to_s
          @vision     = vision
          @aggregates = aggregates
        end

        def aggregate(named) = @aggregates.find { |a| a.name == named.to_s }

        # Every command in the domain, as fully-qualified verbs.
        #   => ["Pizzas::Pizza.CreatePizza", "Pizzas::Pizza.AddTopping", ...]
        def verbs
          @aggregates.flat_map do |agg|
            agg.commands.map { |cmd| "#{@name}::#{agg.name}.#{cmd.name}" }
          end
        end

        def to_h
          {
            name:             @name,
            vision:           @vision,
            aggregates:       @aggregates.map(&:to_h),
            policies:         @policies.map(&:to_h),
            process_managers: @process_managers.map(&:to_h),
            # THE NORMALISATION TABLE THIS RUNTIME USED, carried in the contract
            # rather than left in code for someone to compare by eye. Every
            # `canonical` above was produced by these rows, so a table that
            # disagrees with the other runtime's is a SPLIT on the very next
            # parity run. The fold's word-boundary divergence lived for as long
            # as it did because nothing diffed this.
            canonical_form:   Expression::CanonicalForm.table
          }
        end
      end
    end
  end
end
