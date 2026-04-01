# GoHecks::PortGenerator
#
# Generates a Go interface for a repository port. Ports are Go's native
# abstraction — compile-time enforcement, not runtime NotImplementedError.
#
#   PortGenerator.new(aggregate, package: "domain").generate
#
module GoHecks
  class PortGenerator
    include GoUtils

    def initialize(aggregate, package:)
      @agg = aggregate
      @package = package
    end

    def generate
      n = @agg.name
      v = GoUtils.camel_case(n)
      b = GoCodeBuilder.new(@package)
      b.line("type #{n}Repository interface {")
      b.line("\tFind(id string) (*#{n}, error)")
      b.line("\tSave(#{v} *#{n}) error")
      b.line("\tAll() ([]*#{n}, error)")
      b.line("\tDelete(id string) error")
      b.line("\tCount() (int, error)")
      b.line("}")
      b.to_s
    end
  end
end
