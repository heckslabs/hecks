# Bluebook — one bounded context: a vision sentence and the aggregates inside
# it. This is the whole domain IR, and the thing every other target (Rust, SQL,
# tests, docs) is eventually a PROJECTION of.
#
# Ruby holds the semantics ; everything else is generated downstream. That
# inversion is the point of hecksagain — there is exactly one author.
#
#   Bluebook.new(name: "Pizzas", vision: "...", aggregates: [...])
module Hecksagain
  module IR
    class Bluebook
      attr_reader :name, :vision, :aggregates

      def initialize(name:, vision: nil, aggregates: [])
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
        { name: @name, vision: @vision, aggregates: @aggregates.map(&:to_h) }
      end
    end
  end
end
