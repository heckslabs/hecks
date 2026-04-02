# GoHecks::RegisterGenerator
#
# Generates register.go for a domain package — an init() function
# that self-registers the domain module with the runtime registry.
#
#   gen = RegisterGenerator.new(domain, package: "pizzas",
#                                       module_path: "pizzas_domain")
#   gen.generate  # => Go source string for domain/register.go
#
module GoHecks
  class RegisterGenerator
    include GoUtils

    def initialize(domain, package:, module_path:)
      @domain = domain
      @package = package
      @module_path = module_path
    end

    def generate
      lines = []
      lines << "package #{@package}"
      lines << ""
      lines << "import \"#{@module_path}/runtime\""
      lines << ""
      lines << "func init() {"
      lines << "\truntime.Register(runtime.ModuleInfo{"
      lines << "\t\tName:       \"#{@domain.name}\","
      lines << "\t\tAggregates: #{go_string_slice(aggregate_names)},"
      lines << "\t\tCommands:   #{go_string_slice(command_names)},"
      lines << "\t})"
      lines << "}"
      lines.join("\n") + "\n"
    end

    private

    def aggregate_names
      @domain.aggregates.map(&:name)
    end

    def command_names
      @domain.aggregates.flat_map { |agg| agg.commands.map(&:name) }
    end

    def go_string_slice(names)
      return "[]string{}" if names.empty?
      items = names.map { |n| "\"#{n}\"" }.join(", ")
      "[]string{#{items}}"
    end
  end
end
