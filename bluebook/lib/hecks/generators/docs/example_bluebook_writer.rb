# Hecks::Generators::ExampleBluebookWriter
#
# Generates Bluebook and Hecksagon DSL files from domain IR.
# Used by ExampleGenerator to produce the project scaffold files
# alongside the example script.
#
#   writer = ExampleBluebookWriter.new(domain, aggregates)
#   writer.generate_bluebook   # => "Hecks.domain \"Spec\" do ..."
#   writer.generate_hecksagon  # => "Hecks.hecksagon \"Spec\" do ..."
#
module Hecks
  module Generators
    class ExampleBluebookWriter
      def initialize(domain, aggregates)
        @domain = domain
        @aggregates = aggregates
      end

      def generate_bluebook
        lines = []
        lines << "Hecks.domain #{@domain.name.inspect} do"
        @aggregates.each { |agg| lines << aggregate_block(agg) }
        lines << "end"
        lines.join("\n")
      end

      def generate_hecksagon
        agg_names = @aggregates.map(&:name)
        lines = []
        lines << "# #{@domain.name} Hecksagon"
        lines << "#"
        lines << "# A Hecksagon configures cross-cutting capabilities for your domain."
        lines << "# Capabilities are IR visitors that add behavior to all aggregates"
        lines << "# at boot time — CRUD, audit trails, PII tagging, and more."
        lines << "#"
        lines << "Hecks.hecksagon #{@domain.name.inspect} do"
        lines << "  # Enable CRUD operations for all aggregates"
        lines << "  capabilities :crud"
        lines << ""
        lines << "  # --- Uncomment to enable additional capabilities ---"
        lines << "  #"
        lines << "  # # Audit trail on every command"
        lines << "  # capabilities :crud, :audit"
        lines << "  #"
        lines << "  # # Tag sensitive fields per aggregate"
        agg_names.first(2).each do |name|
          lines << "  # aggregate #{name.inspect} do"
          lines << "  #   capability.name.pii"
          lines << "  # end"
        end
        lines << "end"
        lines.join("\n") + "\n"
      end

      private

      def aggregate_block(agg)
        lines = []
        lines << "  aggregate #{agg.name.inspect} do"
        lines << "    description #{agg.description.inspect}" if agg.description
        lifecycle_field = agg.lifecycle&.field&.to_s
        agg.attributes.each do |a|
          next if a.name.to_s == lifecycle_field
          lines << attribute_line(a, "    ")
        end
        agg.value_objects.each { |vo| lines << value_object_block(vo) }
        agg.references.each { |ref| lines << "    reference_to #{ref.type.inspect}" }
        lifecycle_block(agg, lines)
        agg.validations.each do |v|
          rules = v.rules.map { |k, val| "#{k}: #{val}" }.join(", ")
          lines << "    validation :#{v.field}, #{rules}"
        end
        agg.commands.each { |cmd| lines << command_block(cmd) }
        agg.queries.each { |q| lines << "    query #{q.name.inspect}" }
        lines << "  end\n"
        lines.join("\n")
      end

      def attribute_line(attr, indent)
        type = attr.list? ? "list_of(#{attr.type.inspect})" : attr.type
        default = attr.default ? ", default: #{attr.default.inspect}" : ""
        "#{indent}attribute :#{attr.name}, #{type}#{default}"
      end

      def value_object_block(vo)
        lines = []
        lines << "\n    value_object #{vo.name.inspect} do"
        lines << "      description #{vo.description.inspect}" if vo.description
        vo.attributes.each { |a| lines << attribute_line(a, "      ") }
        vo.invariants.each { |inv| lines << "      invariant #{inv.message.inspect}" }
        lines << "    end"
        lines.join("\n")
      end

      def command_block(cmd)
        attrs = cmd.attributes.reject { |a| a.name.to_s == "aggregate_id" }
        if attrs.empty? && !cmd.description
          return "    command #{cmd.name.inspect}"
        end
        lines = []
        lines << "    command #{cmd.name.inspect} do"
        lines << "      description #{cmd.description.inspect}" if cmd.description
        attrs.each { |a| lines << attribute_line(a, "      ") }
        lines << "    end"
        lines.join("\n")
      end

      def lifecycle_block(agg, lines)
        lc = agg.lifecycle
        return unless lc
        lines << "    attribute :#{lc.field}, String, default: #{lc.default.inspect} do"
        lc.transitions.each do |cmd_name, transition|
          lines << "      transition #{cmd_name.inspect} => #{transition.target.inspect}"
        end
        lines << "    end"
      end
    end
  end
end
