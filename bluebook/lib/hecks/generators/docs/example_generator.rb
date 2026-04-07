# Hecks::Generators::ExampleGenerator
#
# Generates a single documented Ruby example file, its Bluebook,
# and its Hecksagon from domain IR. Pulls descriptions from
# aggregate, command, and value object metadata. The output is
# a runnable script that demonstrates the full domain API.
#
#   gen = Hecks::Generators::ExampleGenerator.new(domain, aggregates: ["Pizza", "Order"])
#   gen.generate  # => { "example.rb" => "...", "SpecBluebook" => "...", "SpecHecksagon" => "..." }
#
require_relative "example_bluebook_writer"

module Hecks
  module Generators
    class ExampleGenerator < Hecks::Generator
      # @param domain [Domain] the domain IR
      # @param aggregates [Array<String>, nil] aggregate names to include (nil = all)
      def initialize(domain, aggregates: nil)
        @domain = domain
        @filter = aggregates&.map(&:to_s)
      end

      def generate
        writer = ExampleBluebookWriter.new(@domain, included_aggregates)
        {
          "example.rb" => generate_example,
          "#{@domain.name}Bluebook" => writer.generate_bluebook,
          "#{@domain.name}Hecksagon" => writer.generate_hecksagon
        }
      end

      def generate_example
        lines = []
        lines << header
        lines << boot_section
        included_aggregates.each { |agg| lines << aggregate_section(agg) }
        lines << event_history_section
        lines.join("\n")
      end

      private

      def included_aggregates
        aggs = @domain.aggregates.select { |a| a.commands.any? }
        aggs = aggs.select { |a| @filter.include?(a.name) } if @filter
        aggs
      end

      def header
        <<~RUBY
          #!/usr/bin/env ruby
          # #{@domain.name} — generated example
          #
          # This file is auto-generated from Bluebook metadata.
          # Every comment below is pulled from the domain definition.
          #
        RUBY
      end

      def boot_section
        <<~RUBY
          require "hecks"

          # Boot the #{@domain.name} domain
          app = Hecks.boot(__dir__)

        RUBY
      end

      def aggregate_section(agg)
        lines = []
        lines << separator(agg.name)
        lines << "# #{agg.description}" if agg.description
        lines << "#"
        lines << attributes_doc(agg)
        lines << value_objects_doc(agg)
        lines << references_doc(agg)
        lines << validations_doc(agg)
        lines << lifecycle_doc(agg)
        lines << ""
        lines << commands_section(agg)
        lines << queries_section(agg)
        lines.compact.join("\n")
      end

      def separator(name)
        "# #{"—" * 60}\n# #{name}\n# #{"—" * 60}"
      end

      def attributes_doc(agg)
        return nil if agg.attributes.empty?
        header = "# Attributes:"
        rows = agg.attributes.map do |attr|
          type_label = attr.list? ? "list of #{attr.type}" : attr.type.to_s
          default = attr.default ? " (default: #{attr.default.inspect})" : ""
          "#   #{attr.name}: #{type_label}#{default}"
        end
        [header, *rows].join("\n")
      end

      def value_objects_doc(agg)
        return nil if agg.value_objects.empty?
        agg.value_objects.map { |vo| value_object_doc(vo) }.join("\n")
      end

      def value_object_doc(vo)
        lines = ["#", "# Value Object: #{vo.name}"]
        lines << "#   #{vo.description}" if vo.description
        vo.attributes.each { |attr| lines << "#   #{attr.name}: #{attr.type}" }
        vo.invariants.each { |inv| lines << "#   invariant: #{inv.message}" }
        lines.join("\n")
      end

      def references_doc(agg)
        return nil if agg.references.empty?
        lines = ["#", "# References:"]
        agg.references.each { |ref| lines << "#   #{ref.name} -> #{ref.type}" }
        lines.join("\n")
      end

      def validations_doc(agg)
        return nil if agg.validations.empty?
        lines = ["#", "# Validations:"]
        agg.validations.each do |v|
          rules = v.rules.map { |k, val| "#{k}: #{val}" }.join(", ")
          lines << "#   #{v.field}: #{rules}"
        end
        lines.join("\n")
      end

      def lifecycle_doc(agg)
        lc = agg.lifecycle
        return nil unless lc
        lines = ["#", "# Lifecycle (#{lc.field}):"]
        lines << "#   default: #{lc.default.inspect}" if lc.default
        lc.transitions.each do |cmd_name, transition|
          lines << "#   #{cmd_name} => #{transition.target}"
        end
        lines.join("\n")
      end

      def commands_section(agg)
        agg.commands.map { |cmd| command_example(agg, cmd) }.join("\n\n")
      end

      def command_example(agg, cmd)
        lines = []
        lines << "# #{cmd.description}" if cmd.description
        attrs = cmd.attributes.reject { |a| a.name.to_s == "aggregate_id" }
        args = attrs.map { |attr| "#{attr.name}: #{example_value(attr)}" }
        method = snake(cmd.name)
        lines << if args.any?
                   "#{agg.name}.#{method}(#{args.join(", ")})"
                 else
                   "#{agg.name}.#{method}"
                 end
        lines.join("\n")
      end

      def queries_section(agg)
        return nil if agg.queries.empty?
        lines = agg.queries.map do |q|
          "# Query: #{q.name}\n#{agg.name}.#{snake(q.name)}"
        end
        "\n" + lines.join("\n\n")
      end

      def event_history_section
        <<~RUBY

          # ————————————————————————————————————————————————————————————
          # Event history
          # ————————————————————————————————————————————————————————————
          app.events.each_with_index do |event, i|
            name = event.class.name.split("::").last
            puts "\#{i + 1}. \#{name} at \#{event.occurred_at}"
          end
        RUBY
      end

      def example_value(attr)
        case attr.type.to_s
        when "String" then "\"example_#{attr.name}\""
        when "Integer" then "1"
        when "Float" then "1.0"
        when "Boolean", "TrueClass", "FalseClass" then "true"
        else "\"example\""
        end
      end

      def snake(name)
        name.gsub(/([a-z])([A-Z])/, '\1_\2').downcase
      end
    end
  end
end
