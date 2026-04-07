# NodeHecks::ServerGenerator
#
# Generates an Express REST server with JSON routes for each aggregate.
# Produces GET /aggregates, GET /aggregates/:id, and POST /aggregates
# endpoints backed by in-memory repositories.
#
#   gen = ServerGenerator.new(domain)
#   gen.generate  # => TypeScript source string for src/server.ts
#
module NodeHecks
  class ServerGenerator
    include NodeUtils

    def initialize(domain)
      @domain = domain
    end

    def generate
      lines = []
      lines.concat(imports)
      lines << ""
      lines.concat(repo_setup)
      lines << ""
      lines.concat(routes)
      lines << ""
      lines.concat(listen)
      NodeUtils.join_lines(lines)
    end

    private

    def imports
      lines = []
      lines << 'import express from "express";'
      @domain.aggregates.each do |agg|
        slug = NodeUtils.snake_case(agg.name)
        lines << NodeUtils.ts_import("#{agg.name}Repository", "./repositories/#{slug}_repository")
        agg.commands.each do |cmd|
          fn = NodeUtils.camel_case(cmd.name)
          lines << NodeUtils.ts_import(fn, "./commands/#{NodeUtils.snake_case(cmd.name)}")
        end
      end
      lines
    end

    def repo_setup
      lines = []
      lines << "const app = express();"
      lines << "app.use(express.json());"
      lines << ""
      @domain.aggregates.each do |agg|
        var = "#{NodeUtils.camel_case(agg.name)}Repo"
        lines << "const #{var} = new #{agg.name}Repository();"
      end
      lines
    end

    def routes
      lines = []
      @domain.aggregates.each do |agg|
        slug = NodeUtils.snake_case(agg.name)
        plural = "#{slug}s"
        repo_var = "#{NodeUtils.camel_case(agg.name)}Repo"

        lines << ""
        lines << "// #{agg.name} routes"
        lines.concat(NodeUtils.express_list_route("/#{plural}", repo_var))
        lines << ""
        lines.concat(NodeUtils.express_detail_route("/#{plural}", repo_var))

        agg.commands.each do |cmd|
          fn = NodeUtils.camel_case(cmd.name)
          cmd_slug = NodeUtils.snake_case(cmd.name)
          lines << ""
          lines.concat(NodeUtils.express_command_route("/#{plural}/#{cmd_slug}", fn, repo_var))
        end
      end
      lines
    end

    def listen
      lines = []
      lines << "const port = process.env.PORT ? parseInt(process.env.PORT) : 3000;"
      lines << "app.listen(port, () => {"
      lines << "  console.log(`#{@domain.name}Domain on http://localhost:${port}`);"
      lines << "});"
      lines
    end
  end
end
