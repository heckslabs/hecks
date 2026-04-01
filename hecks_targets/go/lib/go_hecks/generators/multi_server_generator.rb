# GoHecks::MultiServerGenerator
#
# Generates a combined Go HTTP server that routes requests across
# multiple bounded context packages. Each domain's aggregates get
# JSON API endpoints prefixed by domain package name.
#
#   gen = MultiServerGenerator.new([pizzas, orders], module_path: "multi_domain")
#   gen.generate  # => Go source string for server/server.go
#
module GoHecks
  class MultiServerGenerator
    include GoUtils

    def initialize(domains, module_path:)
      @domains = domains
      @module_path = module_path
    end

    def generate
      lines = []
      lines << "package server"
      lines << ""
      lines.concat(imports)
      lines.concat(app_struct)
      lines.concat(new_app)
      lines.concat(start_method)
      lines.concat(helper_methods)
      lines.join("\n") + "\n"
    end

    private

    def domain_packages
      @domains.map { |d| GoUtils.snake_case(d.name) }
    end

    def imports
      lines = []
      lines << "import ("
      lines << "\t\"encoding/json\""
      lines << "\t\"fmt\""
      lines << "\t\"net/http\""
      domain_packages.each do |pkg|
        lines << "\t\"#{@module_path}/#{pkg}\""
        lines << "\t#{pkg}mem \"#{@module_path}/#{pkg}/adapters/memory\""
      end
      lines << "\t\"#{@module_path}/runtime\""
      lines << ")"
      lines << ""
      lines
    end

    def app_struct
      lines = []
      lines << "type App struct {"
      @domains.each do |domain|
        pkg = GoUtils.snake_case(domain.name)
        domain.aggregates.each do |agg|
          lines << "\t#{pkg}#{agg.name}Repo #{pkg}.#{agg.name}Repository"
        end
      end
      lines << "\tEventBus *runtime.EventBus"
      lines << "\tCommandBus *runtime.CommandBus"
      lines << "}"
      lines << ""
      lines
    end

    def new_app
      lines = []
      lines << "func NewApp() *App {"
      lines << "\teventBus := runtime.NewEventBus()"
      lines << "\treturn &App{"
      @domains.each do |domain|
        pkg = GoUtils.snake_case(domain.name)
        domain.aggregates.each do |agg|
          lines << "\t\t#{pkg}#{agg.name}Repo: #{pkg}mem.New#{agg.name}MemoryRepository(),"
        end
      end
      lines << "\t\tEventBus: eventBus,"
      lines << "\t\tCommandBus: runtime.NewCommandBus(eventBus),"
      lines << "\t}"
      lines << "}"
      lines << ""
      lines
    end

    def start_method
      lines = []
      lines << "func (app *App) Start(port int) error {"
      lines << "\tmux := http.NewServeMux()"
      lines << ""
      lines.concat(home_route)
      @domains.each do |domain|
        lines.concat(domain_routes(domain))
      end
      lines << "\taddr := fmt.Sprintf(\":%d\", port)"
      lines << "\tfmt.Printf(\"Multi-domain server on http://localhost%s\\n\", addr)"
      lines << "\treturn http.ListenAndServe(addr, mux)"
      lines << "}"
      lines << ""
      lines
    end

    def home_route
      lines = []
      lines << "\tmux.HandleFunc(\"GET /{$}\", func(w http.ResponseWriter, r *http.Request) {"
      lines << "\t\tw.Header().Set(\"Content-Type\", \"application/json\")"
      domain_list = @domains.map { |d| "\"#{d.name}\"" }.join(", ")
      lines << "\t\tjson.NewEncoder(w).Encode(map[string]interface{}{\"domains\": []string{#{domain_list}}})"
      lines << "\t})"
      lines << ""
      lines
    end

    def domain_routes(domain)
      pkg = GoUtils.snake_case(domain.name)
      lines = []
      lines << "\t// --- #{domain.name} routes ---"

      domain.aggregates.each do |agg|
        plural = GoUtils.snake_case(agg.name) + "s"
        repo = "app.#{pkg}#{agg.name}Repo"

        # Index
        lines << "\tmux.HandleFunc(\"GET /#{pkg}/#{plural}\", func(w http.ResponseWriter, r *http.Request) {"
        lines << "\t\titems, _ := #{repo}.All()"
        lines << "\t\tjsonResponse(w, items)"
        lines << "\t})"

        # Find
        lines << "\tmux.HandleFunc(\"GET /#{pkg}/#{plural}/find\", func(w http.ResponseWriter, r *http.Request) {"
        lines << "\t\titem, _ := #{repo}.Find(r.URL.Query().Get(\"id\"))"
        lines << "\t\tif item == nil { http.Error(w, `{\"error\":\"not found\"}`, 404); return }"
        lines << "\t\tjsonResponse(w, item)"
        lines << "\t})"

        # Command routes
        agg.commands.each do |cmd|
          cmd_snake = GoUtils.snake_case(cmd.name)
          lines << "\tmux.HandleFunc(\"POST /#{pkg}/#{plural}/#{cmd_snake}/submit\", func(w http.ResponseWriter, r *http.Request) {"
          lines << "\t\tvar cmd #{pkg}.#{cmd.name}"
          lines << "\t\tif err := json.NewDecoder(r.Body).Decode(&cmd); err != nil {"
          lines << "\t\t\thttp.Error(w, `{\"error\":\"invalid json\"}`, 400); return"
          lines << "\t\t}"
          lines << "\t\tagg, event, err := cmd.Execute(#{repo})"
          lines << "\t\tif event != nil { app.EventBus.Publish(event) }"
          lines << "\t\tif err != nil { jsonError(w, err); return }"
          lines << "\t\tw.WriteHeader(201)"
          lines << "\t\tjsonResponse(w, agg)"
          lines << "\t})"
        end
        lines << ""
      end
      lines
    end

    def helper_methods
      [
        "func jsonResponse(w http.ResponseWriter, data interface{}) {",
        "\tw.Header().Set(\"Content-Type\", \"application/json\")",
        "\tjson.NewEncoder(w).Encode(data)",
        "}",
        "",
        "func jsonError(w http.ResponseWriter, err error) {",
        "\tw.Header().Set(\"Content-Type\", \"application/json\")",
        "\tw.WriteHeader(422)",
        "\tjson.NewEncoder(w).Encode(map[string]string{\"error\": err.Error()})",
        "}",
      ]
    end
  end
end
