# Hecks::Capabilities::ProjectDiscovery::Bridge
#
# Discovers and boots Hecks apps, reads their domain IR,
# and provides state serialization for connected clients.
#
#   bridge = Bridge.new
#   bridge.discover(Dir.pwd).each { |p| bridge.open_project(p) }
#   bridge.to_state  # => { projects: [...], stats: {...} }
#
require_relative "diagram_builder"

module Hecks
  module Capabilities
    module ProjectDiscovery
      class Bridge
        include DiagramBuilder

        attr_reader :projects

        def initialize
          @projects = {}
        end

        def open_project(path)
          path = File.expand_path(path)
          return @projects[path] if @projects[path]

          result = Hecks.boot(path)
          runtimes = result.is_a?(Array) ? result : [result]
          domains = runtimes.map do |rt|
            d = rt.domain
            { name: d.name, aggregates: d.aggregates.map { |a| aggregate_info(a) }, domain: d }
          end

          world = Hecks.respond_to?(:last_world) ? Hecks.last_world : nil
          @projects[path] = {
            name: File.basename(path), path: path,
            files: discover_files(path), domains: domains,
            runtimes: runtimes, world: world&.to_h
          }
        rescue => e
          { name: File.basename(path), path: path, error: e.message }
        end

        def discover(search_path)
          Dir.glob(File.join(search_path, "**/hecks/*.bluebook"))
             .map { |f| File.dirname(File.dirname(f)) }
             .uniq.sort
        end

        def file_content(path)
          { filename: File.basename(path), content: File.read(path) }
        rescue => e
          { filename: File.basename(path), content: "# Error: #{e.message}" }
        end

        def all_domains = @projects.values.flat_map { |p| p[:domains] || [] }
        def all_runtimes = @projects.values.flat_map { |p| p[:runtimes] || [] }
        def total_aggregates = all_domains.sum { |d| d[:aggregates]&.size || 0 }

        def refresh
          paths = @projects.keys.dup
          @projects.clear
          paths.each { |p| open_project(p) }
        end

        def search(query)
          return [] unless query && !query.empty?
          q = query.downcase
          all_domains.flat_map do |d|
            matches = []
            matches << { type: "domain", name: d[:name] } if d[:name].downcase.include?(q)
            d[:aggregates]&.each do |a|
              matches << { type: "aggregate", name: a[:name], domain: d[:name] } if a[:name].downcase.include?(q)
              a[:commands]&.each do |c|
                matches << { type: "command", name: c, aggregate: a[:name], domain: d[:name] } if c.downcase.include?(q)
              end
            end
            matches
          end
        end

        def to_state
          worlds = @projects.values.map { |p| p[:world] }.compact
          {
            projects: @projects.map { |path, p|
              {
                name: p[:name], path: path, error: p[:error],
                files: p[:files], world: p[:world],
                domains: (p[:domains] || []).map { |d|
                  { name: d[:name], aggregates: d[:aggregates], policies: policies_for(d[:domain]) }
                }
              }
            },
            world: worlds.first,
            stats: { domains: all_domains.size, aggregates: total_aggregates }
          }
        end

        private

        def aggregate_info(agg)
          {
            name: agg.name,
            description: agg.respond_to?(:description) ? agg.description : nil,
            commands: agg.commands.map(&:name),
            references: agg.respond_to?(:references) ? agg.references.map { |r| r.respond_to?(:name) ? r.name : r.to_s } : []
          }
        end

        def policies_for(domain)
          return [] unless domain&.respond_to?(:policies)
          domain.policies.select(&:reactive?).map do |p|
            { name: p.name, event: p.event_name, command: p.trigger_command, defaults: p.defaults }
          end
        rescue
          []
        end

        def discover_files(path)
          hecks_dir = File.join(path, "hecks")
          hecks_files = Dir.glob(File.join(hecks_dir, "*")).map { |f| { name: File.basename(f), path: f } }
          rb_files = Dir.glob(File.join(path, "*.rb")).map { |f| { name: File.basename(f), path: f } }
          hecks_files + rb_files
        end
      end
    end
  end
end
