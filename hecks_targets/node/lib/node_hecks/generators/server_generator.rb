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
      lines.join("\n") + "\n"
    end

    private

    def imports
      lines = []
      lines << 'import express from "express";'
      @domain.aggregates.each do |agg|
        slug = NodeUtils.snake_case(agg.name)
        lines << "import { #{agg.name}Repository } from \"./repositories/#{slug}_repository\";"
        agg.commands.each do |cmd|
          fn = NodeUtils.camel_case(cmd.name)
          lines << "import { #{fn} } from \"./commands/#{NodeUtils.snake_case(cmd.name)}\";"
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
        lines << "app.get(\"/#{plural}\", (_req, res) => {"
        lines << "  res.json(#{repo_var}.all());"
        lines << "});"
        lines << ""
        lines << "app.get(\"/#{plural}/:id\", (req, res) => {"
        lines << "  const entity = #{repo_var}.find(req.params.id);"
        lines << "  if (!entity) { res.status(404).json({ error: \"Not found\" }); return; }"
        lines << "  res.json(entity);"
        lines << "});"

        agg.commands.each do |cmd|
          fn = NodeUtils.camel_case(cmd.name)
          cmd_slug = NodeUtils.snake_case(cmd.name)
          lines << ""
          lines << "app.post(\"/#{plural}/#{cmd_slug}\", (req, res) => {"
          lines << "  try {"
          lines << "    const event = #{fn}(req.body, #{repo_var});"
          lines << "    res.status(201).json(event);"
          lines << "  } catch (err: unknown) {"
          lines << "    const message = err instanceof Error ? err.message : \"Unknown error\";"
          lines << "    res.status(422).json({ error: message });"
          lines << "  }"
          lines << "});"
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
