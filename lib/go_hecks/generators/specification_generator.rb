# GoHecks::SpecificationGenerator
#
# Generates Go specification structs with SatisfiedBy method.
# Extracts predicate logic from the DSL block source and translates
# to Go comparisons.
#
module GoHecks
  class SpecificationGenerator
    include GoUtils

    def initialize(spec, aggregate_name:, package:)
      @spec = spec
      @agg = aggregate_name
      @package = package
      @predicate = extract_predicate
    end

    def generate
      param = GoUtils.camel_case(@agg)
      type_name = "#{@agg}#{@spec.name}"
      lines = []
      lines << "package #{@package}"
      lines << ""
      lines << "type #{type_name} struct{}"
      lines << ""
      lines << "func (s #{type_name}) SatisfiedBy(#{param} *#{@agg}) bool {"
      if @predicate
        lines << "\treturn #{@predicate}"
      else
        lines << "\treturn true // TODO: translate predicate"
      end
      lines << "}"

      lines.join("\n") + "\n"
    end

    private

    # Extract predicate from DSL block source.
    # Translates Ruby field access to Go: `loan.principal > 50_000` → `loan.Principal > 50000`
    def extract_predicate
      return nil unless @spec.block.source_location
      file, line = @spec.block.source_location
      return nil unless File.exist?(file)

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

      # Find the predicate line (skip the block opener)
      body = block_lines[1..-2]&.map(&:strip)&.reject(&:empty?)&.join(" && ")
      return nil if body.nil? || body.empty?

      # Check for Ruby-specific syntax that can't be translated
      return nil if body.include?(".to_s") || body.include?("Date.") || body.include?("Time.")
      return nil if body.include?(".any?") || body.include?(".all?") || body.include?(".map")
      return nil if body.include?("?") # Safe navigation or ternary
      return nil if body =~ /\w+\.\w+ && \w+\.\w+ && / # nil-check chains (Ruby idiom)

      # Translate Ruby to Go:
      ruby_param = @spec.block.parameters.first&.last&.to_s || GoUtils.camel_case(@agg)
      go_param = GoUtils.camel_case(@agg)
      # Replace ruby_param.field with go_param.Field
      go_pred = body.gsub(/#{ruby_param}\.(\w+)/) { "#{go_param}.#{GoUtils.pascal_case($1)}" }
      go_pred = go_pred.gsub(/(\d)_(\d)/, '\1\2') # Remove number underscores
      go_pred
    end
  end
end
