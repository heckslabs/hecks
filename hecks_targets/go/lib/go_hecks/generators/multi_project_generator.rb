require "fileutils"

# GoHecks::MultiProjectGenerator
#
# Generates a multi-domain Go project where each bounded context
# gets its own Go package. Produces shared runtime, a combined
# server routing all domains, and a single go.mod/main.go.
#
#   domains = [pizzas_domain, orders_domain]
#   gen = MultiProjectGenerator.new(domains, output_dir: "examples")
#   gen.generate  # => path to generated multi-domain Go project
#
module GoHecks
  class MultiProjectGenerator
    include GoUtils

    def initialize(domains, output_dir: ".", name: "multi_domain")
      @domains = domains
      @output_dir = output_dir
      @name = name
    end

    def generate
      @root = File.join(@output_dir, "#{@name}_static_go")
      @module_path = @name
      FileUtils.mkdir_p(@root)

      generate_go_mod
      generate_runtime
      generate_domain_packages
      generate_server
      generate_main

      @root
    end

    private

    def write(path, content)
      full = Hecks::Utils.safe_path!(@root, path)
      FileUtils.mkdir_p(File.dirname(full))
      File.write(full, content)
    end

    def generate_go_mod
      write("go.mod", <<~MOD)
        module #{@module_path}

        go 1.22

        require (
        \tgithub.com/google/uuid v1.6.0
        )
      MOD
    end

    def generate_runtime
      gen = RuntimeGenerator.new
      write("runtime/eventbus.go", gen.generate_event_bus)
      write("runtime/commandbus.go", gen.generate_command_bus)
    end

    def generate_domain_packages
      @domains.each do |domain|
        ProjectGenerator.new(
          domain,
          subdomain_mode: true,
          module_path: @module_path,
          root: @root
        ).generate
      end
    end

    def generate_server
      gen = MultiServerGenerator.new(@domains, module_path: @module_path)
      write("server/server.go", gen.generate)
    end

    def generate_main
      lines = []
      lines << "package main"
      lines << ""
      lines << "import ("
      lines << "\t\"fmt\""
      lines << "\t\"os\""
      lines << "\t\"strconv\""
      lines << "\t\"#{@module_path}/server\""
      lines << ")"
      lines << ""
      lines << "func main() {"
      lines << "\tport := 9292"
      lines << "\tif p := os.Getenv(\"PORT\"); p != \"\" {"
      lines << "\t\tif v, err := strconv.Atoi(p); err == nil { port = v }"
      lines << "\t}"
      lines << "\tif len(os.Args) > 1 {"
      lines << "\t\tif v, err := strconv.Atoi(os.Args[1]); err == nil { port = v }"
      lines << "\t}"
      lines << "\tapp := server.NewApp()"
      lines << "\tif err := app.Start(port); err != nil {"
      lines << "\t\tfmt.Fprintf(os.Stderr, \"Error: %v\\n\", err)"
      lines << "\t\tos.Exit(1)"
      lines << "\t}"
      lines << "}"
      write("cmd/main/main.go", lines.join("\n") + "\n")
    end
  end
end
