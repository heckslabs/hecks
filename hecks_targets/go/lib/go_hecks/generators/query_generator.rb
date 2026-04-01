# GoHecks::QueryGenerator
#
# Generates Go query functions. Extracts where conditions from the
# DSL block source and generates field-matching filter logic.
#
module GoHecks
  class QueryGenerator
    include GoUtils

    def initialize(query, aggregate:, package:, module_path:)
      @query = query
      @agg = aggregate
      @package = package
      @module_path = module_path
      @conditions = extract_conditions
      @params = @query.block.parameters.map { |_, n| n.to_s }
      @attr_index = @agg.attributes.each_with_object({}) { |a, h| h[a.name.to_s] = a }
    end

    def generate
      safe = @agg.name
      query_pascal = GoUtils.pascal_case(@query.name)
      func_name = "#{safe}#{query_pascal}"
      lines = []
      lines << "package #{@package}"
      lines << ""

      if @params.empty?
        lines << "func #{func_name}(repo #{safe}Repository) ([]*#{safe}, error) {"
      else
        param_list = @params.map { |p| "#{p} #{param_go_type(p)}" }.join(", ")
        lines << "func #{func_name}(repo #{safe}Repository, #{param_list}) ([]*#{safe}, error) {"
      end

      lines << "\tall, err := repo.All()"
      lines << "\tif err != nil { return nil, err }"

      if @conditions.empty?
        lines << "\treturn all, nil"
      else
        lines << "\tvar results []*#{safe}"
        lines << "\tfor _, item := range all {"
        checks = @conditions.map do |field, value|
          go_field = GoUtils.pascal_case(field)
          if value[:param]
            "item.#{go_field} == #{value[:param]}"
          else
            "item.#{go_field} == \"#{value[:literal]}\""
          end
        end
        lines << "\t\tif #{checks.join(' && ')} {"
        lines << "\t\t\tresults = append(results, item)"
        lines << "\t\t}"
        lines << "\t}"
        lines << "\treturn results, nil"
      end

      lines << "}"
      lines.join("\n") + "\n"
    end

    private

    def param_go_type(param_name)
      attr = @attr_index[param_name]
      attr ? GoUtils.go_type(attr) : "string"
    end

    # Extract where conditions from the block source.
    # Parses `where(field: "value")` or `where(field: param)` patterns.
    def extract_conditions
      return {} unless @query.block.source_location
      file, line = @query.block.source_location
      return {} unless File.exist?(file)

      # Read lines from the block
      source_lines = File.readlines(file)
      block_lines = []
      depth = 0
      (line - 1).upto(source_lines.size - 1) do |i|
        l = source_lines[i]
        depth += l.scan(/\bdo\b|\{/).size
        depth -= l.scan(/\bend\b|\}/).size
        block_lines << l.strip
        break if depth <= 0
      end

      # Look for where(key: value) pattern
      conditions = {}
      block_lines.each do |l|
        if l =~ /where\((.+)\)/
          pairs = $1
          pairs.scan(/(\w+):\s*(?:"([^"]+)"|(\w+))/).each do |field, str_val, ref_val|
            if str_val
              conditions[field] = { literal: str_val }
            else
              conditions[field] = { param: ref_val }
            end
          end
        end
      end
      conditions
    end
  end
end
