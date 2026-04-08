# Hecks::Appeal::DomainBridge
#
# Discovers and boots Hecks apps, reads their domain IR,
# and provides state serialization for the IDE WebSocket protocol.
#
#   bridge = Hecks::Appeal::DomainBridge.new
#   bridge.open_project("/path/to/app")
#   bridge.to_state  # => { projects: [...], stats: {...} }
#
require_relative "domain_bridge/diagram_builder"

module Hecks
  module Appeal
    class DomainBridge
      include DiagramBuilder

      attr_reader :projects

      def initialize
        @projects = {}
      end

      # Boot a hecks app from a directory and register its domains.
      #
      # @param path [String] directory containing bluebook.hec
      # @return [Hash] project info with domains
      def open_project(path)
        path = File.expand_path(path)
        return @projects[path] if @projects[path]

        result = Hecks.boot(path)
        runtimes = result.is_a?(Array) ? result : [result]
        domains = runtimes.map do |rt|
          d = rt.domain
          {
            name: d.name,
            aggregates: d.aggregates.map { |a| aggregate_info(a) },
            domain: d
          }
        end

        world = Hecks.respond_to?(:last_world) ? Hecks.last_world : nil

        @projects[path] = {
          name: File.basename(path),
          path: path,
          files: discover_files(path),
          domains: domains,
          runtimes: runtimes,
          world: world&.to_h
        }
      rescue => e
        { name: File.basename(path), path: path, error: e.message }
      end

      # Walk a directory tree for bootable hecks apps.
      # Looks for hecks/ directories containing .bluebook files.
      #
      # @param search_path [String] directory to scan recursively
      # @return [Array<String>] paths to hecks app directories
      def discover(search_path)
        Dir.glob(File.join(search_path, "**/hecks/*.bluebook"))
           .map { |f| File.dirname(File.dirname(f)) }
           .uniq
           .sort
      end

      # Read a file and return it with its basename.
      #
      # @param path [String] absolute file path
      # @return [Hash] { filename:, content: }
      def file_content(path)
        { filename: File.basename(path), content: File.read(path) }
      rescue => e
        { filename: File.basename(path), content: "# Error: #{e.message}" }
      end

      # All domains across all open projects.
      def all_domains = @projects.values.flat_map { |p| p[:domains] || [] }

      # All runtimes across all open projects.
      def all_runtimes = @projects.values.flat_map { |p| p[:runtimes] || [] }

      # Total aggregate count across all projects.
      def total_aggregates = all_domains.sum { |d| d[:aggregates]&.size || 0 }

      # Re-discover and reload all projects from their original paths.
      def refresh
        paths = @projects.keys.dup
        @projects.clear
        paths.each { |p| open_project(p) }
      end

      # Search all domains for aggregates, commands matching a query.
      #
      # @param query [String]
      # @return [Array<Hash>]
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

      # Full state dump for initial WebSocket handshake.
      #
      # @return [Hash] all projects/domains/aggregates serialized
      def to_state
        worlds = @projects.values.map { |p| p[:world] }.compact
        {
          projects: @projects.map { |path, p|
            {
              name: p[:name], path: path, error: p[:error],
              files: p[:files],
              world: p[:world],
              domains: (p[:domains] || []).map { |d|
                {
                  name: d[:name],
                  aggregates: d[:aggregates],
                  policies: policies_for(d[:domain])
                }
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
        return [] unless domain && domain.respond_to?(:policies)
        domain.policies.select(&:reactive?).map do |p|
          {
            name: p.name,
            event: p.event_name,
            command: p.trigger_command,
            defaults: p.defaults
          }
        end
      rescue
        []
      end

      def discover_files(path)
        hecks_dir = File.join(path, "hecks")
        hecks_files = Dir.glob(File.join(hecks_dir, "*")).map do |f|
          { name: File.basename(f), path: f }
        end
        rb_files = Dir.glob(File.join(path, "*.rb")).map do |f|
          { name: File.basename(f), path: f }
        end
        hecks_files + rb_files
      end
    end
  end
end
