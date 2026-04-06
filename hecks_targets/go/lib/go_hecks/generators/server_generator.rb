require_relative "server_generator/data_routes"
require_relative "server_generator/html_routes"
require_relative "server_generator/ui_routes"
require_relative "server_generator/domain_behavior_routes"

# GoHecks::ServerGenerator
#
# Generates a Go HTTP server using net/http with JSON API routes,
# HTML UI routes, and domain behavior routes (events, queries,
# scopes, specifications) rendered via html/template.
#
module GoHecks
  class ServerGenerator < Hecks::Generator
    include GoUtils
    include DataRoutes
    include HtmlRoutes
    include UIRoutes
    include DomainBehaviorRoutes

    def initialize(domain, module_path:)
      @domain = domain
      @module_path = module_path
    end

    def generate
      lines = []
      lines << "// Domain: #{@domain.name}"
      lines << "// Version: #{@domain.version || "unversioned"}"
      lines << "package server"
      lines << ""
      lines << "import ("
      lines << "\t\"crypto/rand\""
      lines << "\t\"encoding/hex\""
      lines << "\t\"encoding/json\""
      lines << "\t\"fmt\""
      lines << "\t\"net/http\""
      lines << "\t\"strconv\"" if needs_strconv_import?
      lines << "\t\"time\""
      lines << "\t\"os\""
      lines << "\t\"path/filepath\""
      lines << "\t\"#{@module_path}/domain\""
      lines << "\t\"#{@module_path}/adapters/memory\""
      lines << "\t\"#{@module_path}/runtime\""
      lines << ")"
      lines << ""
      lines.concat(app_struct)
      lines.concat(start_method)
      lines.concat(helper_methods)
      lines.join("\n") + "\n"
    end

    private

    def needs_strconv_import?
      @domain.aggregates.any? do |agg|
        attr_index = agg.attributes.each_with_object({}) { |attr, hash| hash[attr.name.to_s] = attr }
        agg.queries.any? do |query|
          query.block.parameters.any? do |_param_type, param_name|
            attr = attr_index[param_name.to_s]
            attr && %w[int64 float64].include?(GoUtils.go_type(attr))
          end
        end
      end
    end

    def app_struct
      lines = []
      lines << "type App struct {"
      @domain.aggregates.each { |agg| lines << "\t#{agg.name}Repo domain.#{agg.name}Repository" }
      lines << "\tEventBus *runtime.EventBus"
      lines << "\tCommandBus *runtime.CommandBus"
      lines << "\tViewStates map[string]map[string]interface{}" if @domain.views.any?
      lines << "}"
      lines << ""
      lines << "func NewApp() *App {"
      lines << "\teventBus := runtime.NewEventBus()"
      lines << "\treturn &App{"
      @domain.aggregates.each { |agg| lines << "\t\t#{agg.name}Repo: memory.New#{agg.name}MemoryRepository()," }
      lines << "\t\tEventBus: eventBus,"
      lines << "\t\tCommandBus: runtime.NewCommandBus(eventBus),"
      if @domain.views.any?
        view_init = @domain.views.map { |v| "\"#{v.name}\": {}" }.join(", ")
        lines << "\t\tViewStates: map[string]map[string]interface{}{#{view_init}},"
      end
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
      lines << "\tviewsDir := os.Getenv(\"VIEWS_DIR\")"
      lines << "\tif viewsDir == \"\" {"
      lines << "\t\texe, _ := os.Executable()"
      lines << "\t\tviewsDir = filepath.Join(filepath.Dir(exe), \"..\", \"views\")"
      lines << "\t\tif _, err := os.Stat(viewsDir); err != nil {"
      lines << "\t\t\tviewsDir = filepath.Join(filepath.Dir(exe), \"views\")"
      lines << "\t\t}"
      lines << "\t\tif _, err := os.Stat(viewsDir); err != nil { viewsDir = \"views\" }"
      lines << "\t}"
      lines << "\tnav := []NavItem{"
      @domain.aggregates.each do |agg|
        group = agg.origin_domain ? HecksTemplating::UILabelContract.label(agg.origin_domain) : ""
        lines << "\t\t{Label: \"#{HecksTemplating::UILabelContract.plural_label(agg.name)}\", Href: \"/#{GoUtils.snake_case(agg.name)}s\", Group: \"#{group}\"},"
      end
      lines << "\t\t{Label: \"Config\", Href: \"/config\", Group: \"System\"},"
      lines << "\t}"
      lines << "\trenderer := NewRenderer(viewsDir, \"#{HecksTemplating::DisplayContract.domain_label(@domain.name + "Domain")}\", nav)"
      lines << ""
      lines.concat(home_route)
      lines.concat(json_routes)
      lines.concat(html_routes)
      lines.concat(form_routes)
      lines.concat(go_behavior_routes)
      lines.concat(config_route)
      lines << "\taddr := fmt.Sprintf(\":%d\", port)"
      lines << "\tfmt.Printf(\"#{@domain.name}Domain on http://localhost%s\\n\", addr)"
      lines << "\treturn http.ListenAndServe(addr, NewCSRFMiddleware(mux))"
      lines << "}"
      lines << ""
      lines
    end

    def home_route
      agg_data = @domain.aggregates.map do |agg|
        plural = GoUtils.snake_case(agg.name) + "s"
        agg_display = HecksTemplating::DisplayContract.home_aggregate_data(agg, plural)
        "{Name: \"#{agg_display[:name]}\", Href: \"#{agg_display[:href]}\", CommandNames: \"#{agg_display[:command_names]}\", Attributes: #{agg_display[:attributes]}, Policies: #{agg_display[:policies]}}"
      end
      lines = []
      vc = HecksTemplating::ViewContract
      lines << "\t#{vc.go_struct(:home_agg, vc::HOME[:structs][:home_agg])}"
      lines << "\t#{vc.go_struct(:home_data, vc::HOME[:fields])}"
      lines << "\tmux.HandleFunc(\"GET /{$}\", func(w http.ResponseWriter, r *http.Request) {"
      domain_label = HecksTemplating::DisplayContract.domain_label(domain_module_name(@domain.name))
      lines << "\t\trenderer.Render(w, \"home\", \"#{domain_label}\", HomeData{"
      lines << "\t\t\tDomainName: \"#{domain_label}\", Aggregates: []HomeAgg{#{agg_data.join(', ')}},"
      lines << "\t\t})"
      lines << "\t})"
      lines << ""
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
        "",
        "func csrfToken(w http.ResponseWriter, r *http.Request) string {",
        "\tconst cookieName = \"_csrf_token\"",
        "\tif c, err := r.Cookie(cookieName); err == nil && c.Value != \"\" {",
        "\t\treturn c.Value",
        "\t}",
        "\tb := make([]byte, 32)",
        "\trand.Read(b)",
        "\ttoken := hex.EncodeToString(b)",
        "\thttp.SetCookie(w, &http.Cookie{Name: cookieName, Value: token, SameSite: http.SameSiteStrictMode, HttpOnly: true})",
        "\treturn token",
        "}",
        "",
        "type CSRFMiddleware struct{ next http.Handler }",
        "",
        "func NewCSRFMiddleware(next http.Handler) *CSRFMiddleware {",
        "\treturn &CSRFMiddleware{next: next}",
        "}",
        "",
        "func (m *CSRFMiddleware) ServeHTTP(w http.ResponseWriter, r *http.Request) {",
        "\tif r.Method == \"POST\" && r.Header.Get(\"Content-Type\") != \"application/json\" {",
        "\t\tcookie, err := r.Cookie(\"_csrf_token\")",
        "\t\tif err != nil || r.FormValue(\"_csrf_token\") != cookie.Value {",
        "\t\t\thttp.Error(w, \"CSRF validation failed\", http.StatusForbidden)",
        "\t\t\treturn",
        "\t\t}",
        "\t}",
        "\tm.next.ServeHTTP(w, r)",
        "}",
      ]
    end
  end
end
