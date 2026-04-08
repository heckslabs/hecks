# Hecks::Generators::ExampleGenerator
#
# Generates a runnable app, Bluebook, and Hecksagon from domain
# IR. Delegates to ExampleAppWriter for the app script and
# ExampleBluebookWriter for the DSL files.
#
#   gen = Hecks::Generators::ExampleGenerator.new(domain, aggregates: ["Pizza", "Order"])
#   gen.generate  # => { "pizzas.rb" => "...", "bluebook.hec" => "...", "hecksagon.hec" => "..." }
#
Hecks::Chapters.load_aggregates(
  Hecks::Chapters::Bluebook::GeneratorsParagraph,
  base_dir: __dir__
)

module Hecks
  module Generators
    class ExampleGenerator < Hecks::Generator
      # @param domain [Domain] the domain IR
      # @param aggregates [Array<String>, nil] aggregate names to include (nil = all)
      # @param name [String, nil] override domain name in output
      def initialize(domain, aggregates: nil, name: nil)
        @domain = domain
        @filter = aggregates&.map(&:to_s)
        @name = name || domain.name
      end

      # Load domain IR directly from a Bluebook file (no CRUD expansion)
      def self.from_bluebook(path, **opts)
        domain = eval(File.read(path)) # rubocop:disable Security/Eval
        new(domain, **opts)
      end

      def generate
        aggs = included_aggregates
        app = ExampleAppWriter.new(@domain, aggs, name: @name)
        dsl = ExampleBluebookWriter.new(@domain, aggs, name: @name)
        {
          "#{bluebook_snake_name(@name)}.rb" => app.generate,
          "bluebook.hec" => dsl.generate_bluebook,
          "hecksagon.hec" => dsl.generate_hecksagon
        }
      end

      private

      def included_aggregates
        aggs = @domain.aggregates.select { |a| a.commands.any? }
        aggs = aggs.select { |a| @filter.include?(a.name) } if @filter
        aggs
      end
    end
  end
end
