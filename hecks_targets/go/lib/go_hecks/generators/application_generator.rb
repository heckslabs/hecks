# GoHecks::ApplicationGenerator
#
# Generates runtime/application.go — the Go runtime interpreter entry
# point. The Application struct boots the domain by wiring repositories,
# event bus, and command bus, then exposes Run(commandName, jsonAttrs)
# to dispatch commands at runtime and return aggregate + event results.
#
#   gen = ApplicationGenerator.new(domain, module_path: "pizzas_domain")
#   gen.generate  # => Go source string for runtime/application.go
#
module GoHecks
  class ApplicationGenerator
    include GoUtils

    def initialize(domain, module_path:)
      @domain = domain
      @module_path = module_path
    end

    def generate
      lines = []
      lines.concat(header)
      lines.concat(result_struct)
      lines.concat(app_struct)
      lines.concat(boot_method)
      lines.concat(run_method)
      lines.concat(accessor_methods)
      lines.join("\n") + "\n"
    end

    private

    def header
      lines = []
      lines << "package runtime"
      lines << ""
      lines << "import ("
      lines << "\t\"encoding/json\""
      lines << "\t\"fmt\""
      lines << "\t\"#{@module_path}/domain\""
      lines << "\t\"#{@module_path}/adapters/memory\""
      lines << ")"
      lines << ""
      lines
    end

    def result_struct
      lines = []
      lines << "type CommandResult struct {"
      lines << "\tAggregate interface{}"
      lines << "\tEvent     DomainEvent"
      lines << "}"
      lines << ""
      lines
    end

    def app_struct
      lines = []
      lines << "type Application struct {"
      @domain.aggregates.each do |agg|
        lines << "\t#{agg.name}Repo domain.#{agg.name}Repository"
      end
      lines << "\tEventBus   *EventBus"
      lines << "\tCommandBus *CommandBus"
      lines << "}"
      lines << ""
      lines
    end

    def boot_method
      lines = []
      lines << "func Boot() *Application {"
      lines << "\teventBus := NewEventBus()"
      lines << "\treturn &Application{"
      @domain.aggregates.each do |agg|
        lines << "\t\t#{agg.name}Repo: memory.New#{agg.name}MemoryRepository(),"
      end
      lines << "\t\tEventBus:   eventBus,"
      lines << "\t\tCommandBus: NewCommandBus(eventBus),"
      lines << "\t}"
      lines << "}"
      lines << ""
      lines
    end

    def run_method
      lines = []
      lines << "func (app *Application) Run(commandName string, jsonAttrs []byte) (*CommandResult, error) {"
      lines << "\tswitch commandName {"
      @domain.aggregates.each do |agg|
        agg.commands.each do |cmd|
          lines << "\tcase \"#{cmd.name}\":"
          lines << "\t\tvar c domain.#{cmd.name}"
          lines << "\t\tif err := json.Unmarshal(jsonAttrs, &c); err != nil {"
          lines << "\t\t\treturn nil, fmt.Errorf(\"decode %s: %w\", commandName, err)"
          lines << "\t\t}"
          lines << "\t\tagg, event, err := c.Execute(app.#{agg.name}Repo)"
          lines << "\t\tif err != nil { return nil, err }"
          lines << "\t\tapp.EventBus.Publish(event)"
          lines << "\t\treturn &CommandResult{Aggregate: agg, Event: event}, nil"
        end
      end
      lines << "\tdefault:"
      lines << "\t\treturn nil, fmt.Errorf(\"unknown command: %s\", commandName)"
      lines << "\t}"
      lines << "}"
      lines << ""
      lines
    end

    def accessor_methods
      lines = []
      lines << "func (app *Application) Events() []DomainEvent {"
      lines << "\treturn app.EventBus.Events()"
      lines << "}"
      lines << ""
      lines << "func (app *Application) On(eventName string, handler func(DomainEvent)) {"
      lines << "\tapp.EventBus.Subscribe(eventName, handler)"
      lines << "}"
      lines << ""
      lines << "func (app *Application) Repo(name string) interface{} {"
      lines << "\tswitch name {"
      @domain.aggregates.each do |agg|
        lines << "\tcase \"#{agg.name}\":"
        lines << "\t\treturn app.#{agg.name}Repo"
      end
      lines << "\tdefault:"
      lines << "\t\treturn nil"
      lines << "\t}"
      lines << "}"
      lines
    end
  end
end
