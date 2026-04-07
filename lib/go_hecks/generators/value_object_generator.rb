# GoHecks::ValueObjectGenerator
#
# Generates a Go struct for a value object with a constructor that
# validates invariants. Value objects are plain structs — immutability
# is by convention (no pointer receiver mutators).
#
#   ValueObjectGenerator.new(vo, package: "domain").generate
#
module GoHecks
  class ValueObjectGenerator
    include GoUtils

    def initialize(value_object, package:)
      @vo = value_object
      @package = package
    end

    def generate
      b = GoCodeBuilder.new(@package)
      b.imports('"fmt"') if @vo.invariants.any?

      b.struct(@vo.name) do |s|
        @vo.attributes.each do |attr|
          s.field(GoUtils.pascal_case(attr.name), GoUtils.go_type(attr), json: GoUtils.json_tag(attr.name))
        end
      end

      params = @vo.attributes.map { |a| "#{GoUtils.camel_case(a.name)} #{GoUtils.go_type(a)}" }.join(", ")
      b.func("New#{@vo.name}(#{params})", nil, "(#{@vo.name}, error)") do |m|
        m.line("v := #{@vo.name}{")
        @vo.attributes.each do |attr|
          m.line("\t#{GoUtils.pascal_case(attr.name)}: #{GoUtils.camel_case(attr.name)},")
        end
        m.line("}")
        invariant_checks(m)
        m.line("return v, nil")
      end

      b.to_s
    end

    private

    def invariant_checks(m)
      @vo.invariants.each do |inv|
        m.line("// #{inv.message}")
        next unless inv.message =~ /(\w+) must be positive/
        field = GoUtils.pascal_case($1)
        m.line("if v.#{field} <= 0 {")
        m.line("\treturn #{@vo.name}{}, fmt.Errorf(\"#{inv.message}\")")
        m.line("}")
      end
    end
  end
end
