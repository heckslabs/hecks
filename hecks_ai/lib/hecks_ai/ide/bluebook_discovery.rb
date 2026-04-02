# Hecks::AI::IDE::BluebookDiscovery
#
# Discovers all Bluebook and Hecksagon files in a project directory.
# Parses aggregate names from each Bluebook for the sidebar panel.
#
#   discovery = BluebookDiscovery.new("/path/to/project")
#   discovery.apps  # => [{ name: "Pizzas", path: "PizzasBluebook", ... }]
#
module Hecks
  module AI
    module IDE
      class BluebookDiscovery
        def initialize(project_dir)
          @dir = project_dir
        end

        def apps
          results = []
          results.concat(root_books)
          results.concat(multi_books)
          results.concat(example_books)
          { apps: results }
        end

        private

        def root_books
          Dir[File.join(@dir, "*Bluebook")].select { |f| File.file?(f) }.sort.map do |path|
            rel = path.sub("#{@dir}/", "")
            name = File.basename(path).sub(/Bluebook$/, "")
            hex = Dir[File.join(@dir, "*Hecksagon")].first
            {
              name: name, path: rel, type: "single",
              aggregates: parse_aggregates(path),
              hecksagon: hex ? hex.sub("#{@dir}/", "") : nil
            }
          end
        end

        def multi_books
          results = []
          %w[bluebook hecks_domains domains].each do |dir|
            full = File.join(@dir, dir)
            next unless File.directory?(full)
            Dir[File.join(full, "*Bluebook")].sort.each do |path|
              rel = path.sub("#{@dir}/", "")
              name = File.basename(path).sub(/Bluebook$/, "")
              hex_path = File.join(full, "#{name}Hecksagon")
              hex = File.exist?(hex_path) ? hex_path.sub("#{@dir}/", "") : nil
              results << {
                name: name, path: rel, type: "multi", group: dir,
                aggregates: parse_aggregates(path), hecksagon: hex
              }
            end
          end
          results
        end

        def example_books
          dir = File.join(@dir, "examples")
          return [] unless File.directory?(dir)
          Dir[File.join(dir, "**/*Bluebook")].select { |f| File.file?(f) }.sort.map do |path|
            rel = path.sub("#{@dir}/", "")
            name = File.basename(path).sub(/Bluebook$/, "")
            app_dir = File.dirname(path)
            hex = Dir[File.join(app_dir, "*Hecksagon")].first
            {
              name: name, path: rel, type: "example",
              group: File.dirname(rel),
              aggregates: parse_aggregates(path),
              hecksagon: hex ? hex.sub("#{@dir}/", "") : nil
            }
          end
        end

        def parse_aggregates(path)
          File.read(path).scan(/aggregate\s+"([^"]+)"/).flatten
        end
      end
    end
  end
end
