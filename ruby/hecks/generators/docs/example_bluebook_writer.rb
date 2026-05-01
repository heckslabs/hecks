# Hecks::Generators::ExampleBluebookWriter
#
# Generates Bluebook and Hecksagon DSL files from domain IR.
# Used by ExampleGenerator to produce the project scaffold files
# alongside the example script.
#
#   writer = ExampleBluebookWriter.new(domain, aggregates)
#   writer.generate_bluebook   # => "Hecks.bluebook \"Spec\" do ..."
#   writer.generate_hecksagon  # => "Hecks.hecksagon \"Spec\" do ..."
#
module Hecks
  module Generators
    class ExampleBluebookWriter
      def initialize(domain, aggregates, name: nil)
        @domain = domain
        @aggregates = aggregates
        @name = name || domain.name
      end

      def generate_bluebook
        lines = []
        lines << "Hecks.bluebook #{@name.inspect} do"
        @aggregates.each { |agg| lines << aggregate_block(agg) }
        lines << "end"
        lines.join("\n")
      end

      def generate_hecksagon
        agg_names = @aggregates.map(&:name)
        lines = []
        lines << "# #{@name} Hecksagon"
        lines << "#"
        lines << "# A Hecksagon configures cross-cutting capabilities for your domain."
        lines << "# Capabilities are IR visitors that add behavior to all aggregates"
        lines << "# at boot time — CRUD, audit trails, PII tagging, and more."
        lines << "#"
        lines << "Hecks.hecksagon #{@name.inspect} do"
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
        agg.queries.each { |q| lines << query_block(q) }
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
        vo.invariants.each do |inv|
          body = extract_block_body(inv.block, "        ")
          lines << "      invariant #{inv.message.inspect} do"
          lines << body
          lines << "      end"
        end
        lines << "    end"
        lines.join("\n")
      end

      def command_block(cmd)
        attrs = cmd.attributes.reject { |a| a.name.to_s == "aggregate_id" }
        refs = cmd.respond_to?(:references) ? cmd.references : []
        if attrs.empty? && refs.empty? && !cmd.description
          return "    command #{cmd.name.inspect}"
        end
        lines = []
        lines << "    command #{cmd.name.inspect} do"
        lines << "      description #{cmd.description.inspect}" if cmd.description
        refs.each { |r| lines << "      reference_to #{r.type.inspect}" }
        attrs.each { |a| lines << attribute_line(a, "      ") }
        lines << "    end"
        lines.join("\n")
      end

      def query_block(query)
        return "    query #{query.name.inspect}" unless query.block
        header = extract_block_header(query.block)
        body = extract_block_body(query.block, "      ")
        "    query #{query.name.inspect} do#{header}\n#{body}\n    end"
      end

      def extract_block_header(block)
        params = block.parameters.map { |_, n| n }.compact
        params.any? ? " |#{params.join(", ")}|" : ""
      end

      def extract_block_body(block, indent)
        return "#{indent}true" unless block
        file, line = block.source_location
        return "#{indent}true" unless file && File.exist?(file)
        source_lines = File.readlines(file)
        # The block starts on `line` (1-indexed). Body starts on line+1.
        # Read until we hit the closing `end` at or less than the opening indent.
        start = line # 0-indexed: line number is 1-based, so source_lines[line] is the next line
        opening = source_lines[line - 1]
        open_indent = opening[/\A\s*/].length
        body_lines = []
        (start...source_lines.size).each do |i|
          l = source_lines[i]
          break if l.strip == "end" && l[/\A\s*/].length <= open_indent
          body_lines << l
        end
        body_lines.map { |l| "#{indent}#{l.strip}" }.join("\n")
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
