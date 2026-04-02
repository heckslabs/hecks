# Hecks::AI::IDE::BluebookDiscovery
#
# Discovers all Bluebook and Hecksagon files in a project directory.
# Parses aggregate names from each Bluebook for the sidebar panel.
#
#   discovery = BluebookDiscovery.new("/path/to/project")
#   discovery.apps  # => { apps: [{ name: "Pizzas", ... }] }
#
module Hecks
  module AI
    module IDE
      class BluebookDiscovery
        GENERATED_PATTERN = /_static_|_domain\/|_domain$/

        def initialize(project_dir)
          @dir = project_dir
        end

        def apps
          results = []
          results.concat(root_books)
          results.concat(example_books)
          results.reject! { |a| a[:path] =~ GENERATED_PATTERN }
          { apps: results }
        end

        private

        def root_books
          Dir[File.join(@dir, "*Bluebook")].select { |f| File.file?(f) }.sort.map do |path|
            build_entry(path, type: "single")
          end
        end

        def example_books
          dir = File.join(@dir, "examples")
          return [] unless File.directory?(dir)

          # Find all Bluebooks, filter generated, group by app directory
          all = Dir[File.join(dir, "**/*Bluebook")]
            .select { |f| File.file?(f) }
            .reject { |f| f.sub("#{@dir}/", "") =~ GENERATED_PATTERN }
            .sort
          grouped = all.group_by { |path| app_dir(path, dir) }

          grouped.flat_map do |app_name, paths|
            if paths.size == 1
              [build_entry(paths.first, type: "example")]
            else
              paths.map { |p| build_entry(p, type: "multi", group: app_name) }
            end
          end
        end

        def build_entry(path, type:, group: nil)
          rel = path.sub("#{@dir}/", "")
          name = File.basename(path).sub(/Bluebook$/, "")
          app_dir = File.dirname(path)
          hex = Dir[File.join(app_dir, "*Hecksagon")].first
          entry = {
            name: name, path: rel, type: type,
            aggregates: parse_aggregates(path),
            hecksagon: hex ? hex.sub("#{@dir}/", "") : nil
          }
          entry[:group] = group if group
          entry
        end

        # Extract the app name: first directory under examples/
        def app_dir(path, examples_dir)
          relative = path.sub("#{examples_dir}/", "")
          relative.split("/").first
        end

        def parse_aggregates(path)
          File.read(path).scan(/aggregate\s+"([^"]+)"/).flatten
        end
      end
    end
  end
end
