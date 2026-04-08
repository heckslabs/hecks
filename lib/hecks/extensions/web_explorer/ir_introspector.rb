# Hecks::WebExplorer::IRIntrospector
#
# Provides structural queries from the Bluebook IR for the Web Explorer.
# All aggregate names, attribute definitions, command fields, lifecycle
# states, policies, and reference targets come from the IR -- not from
# runtime object inspection.
#
#   ir = IRIntrospector.new(domain)
#   ir.aggregate_names          # => ["Pizza", "Order"]
#   ir.user_attributes("Pizza") # => [<Attribute name: ...>, ...]
#   ir.columns_for("Pizza")     # => [{ label: "Name" }, ...]
#   ir.command_fields(cmd)      # => [{ name: "name", label: "Name", ... }]
#
module Hecks
  module WebExplorer
    # Hecks::WebExplorer::IRIntrospector
    #
    # Provides structural queries from the Bluebook IR for the Web Explorer.
    #
    class IRIntrospector
      include HecksTemplating::NamingHelpers

      attr_reader :domain

      def initialize(domain)
        @domain = domain
      end

      def aggregate_names
        @domain.aggregates.map(&:name)
      end

      def find_aggregate(name)
        @domain.aggregates.find { |agg| agg.name == name }
      end

      def find_aggregate_by_slug(slug)
        @domain.aggregates.find { |agg| bluebook_aggregate_slug(agg.name) == slug }
      end

      def user_attributes(agg)
        agg.attributes.reject { |attr|
          Hecks::Utils::RESERVED_AGGREGATE_ATTRS.include?(attr.name.to_s) || !attr.visible?
        }
      end

      def computed_attributes(agg)
        agg.computed_attributes || []
      end

      def columns_for(agg)
        dc = HecksTemplating::DisplayContract
        cols = user_attributes(agg).map { |a|
          lbl = dc.reference_attr?(a) ? dc.reference_column_label(a) : humanize(a.name)
          { label: lbl }
        }
        computed_attributes(agg).each { |ca| cols << { label: "#{humanize(ca.name)} (computed)" } }
        cols
      end

      def create_commands(agg)
        agg.commands.select { |cmd| cmd.name.start_with?("Create") }
      end

      def find_command(agg, cmd_snake)
        agg.commands.find { |cmd| bluebook_snake_name(cmd.name) == cmd_snake }
      end

      def command_fields(cmd, params = {})
        cmd.attributes.map do |attr|
          if attr.enum
            { type: :enum, name: attr.name.to_s, label: humanize(attr.name),
              options: attr.enum, required: false,
              value: params[attr.name.to_s] || "" }
          else
            { type: :input, name: attr.name.to_s, label: humanize(attr.name),
              input_type: "text", step: false, required: false,
              value: params[attr.name.to_s] || "" }
          end
        end
      end

      def reference_attr?(attr)
        HecksTemplating::DisplayContract.reference_attr?(attr)
      end

      def find_referenced_aggregate(attr)
        HecksTemplating::DisplayContract.find_referenced_aggregate(attr, @domain)
      end

      def field_label(attr)
        if reference_attr?(attr)
          HecksTemplating::DisplayContract.reference_column_label(attr)
        else
          humanize(attr.name)
        end
      end

      def home_aggregate_data(agg, plural_slug)
        HecksTemplating::DisplayContract.home_aggregate_data(agg, plural_slug)
      end

      def aggregate_summary(agg)
        HecksTemplating::DisplayContract.aggregate_summary(agg)
      end

      def filterable_attributes(agg)
        user_attributes(agg).select { |attr| attr.type == String && !attr.list? }
      end

      def policy_labels
        HecksTemplating::DisplayContract.policy_labels(@domain)
      end

      def available_roles
        HecksTemplating::DisplayContract.available_roles(@domain)
      end

      def diagram_data
        viz = Hecks::DomainVisualizer.new(@domain)
        flow = Hecks::FlowGenerator.new(@domain)
        {
          structure_diagram: viz.generate_structure,
          behavior_diagram:  viz.generate_behavior,
          flows_diagram:     flow.generate_mermaid
        }
      end

      private

      def humanize(name)
        Hecks::Utils.humanize(Hecks::Utils.sanitize_constant(name))
      end
    end
  end
end
