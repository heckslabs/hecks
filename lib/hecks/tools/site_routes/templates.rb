# frozen_string_literal: true

require_relative "../../tools"

module Hecks
  module Tools
    module SiteRoutes
      # The edge's half of the projection: the project's template with its regions rewritten.
      module Templates
        # The template with the edge's regions rewritten, when the project declares an edge.
        #
        # @param root [String] the project directory
        # @param out [String, nil] the directory to write to, or nil to rewrite the template in
        #   place
        # @param site [Site] the chapter that declares the route table, its checked table and
        #   registry
        # @param template [String, nil] a template named on the command line, rewritten in place
        # @return [Hash{String => String}] the template's path to its text; empty with no edge
        # @raise [SystemExit] when a template is named and the project declares no edge, the
        #   template is missing or lacks a region it needs, or holds a region an edge without a load
        #   balancer does not use
        def template_files(root, out, site, template: nil)
          edge = Projections::Site::Edge.read(site.chapter, table: site.table, template: template,
                                                            vocabulary: Projections::Site::Table.vocabulary(site.registry))
          return missing_edge(template) unless edge

          regions = Projector.call(:site_cdn, bluebook: site.chapter, options: { table: site.table, edge: edge })
          relative = template || edge.setting.template
          source = template_source(root, template, relative)
          text = rewritten(File.read(source), regions, relative, edge)
          { destination(source, out, template, relative) => text }
        end

        # @param text [String] the template
        # @param regions [Hash{String => String}] each region's name to the block that goes in it
        # @param relative [String] the template's name, for a message
        # @param edge [Projections::Site::Edge] the checked edge
        # @return [String] the template with each region rewritten
        # @raise [SystemExit] when a region is missing, or a listener_rules region is left behind
        #   by an edge with no load balancer
        def rewritten(text, regions, relative, edge)
          if !edge.alb? && Projections::Site::Regions.region?(text, "listener_rules")
            abort "project_site: #{relative} has a BEGIN/END GENERATED site_cdn listener_rules region, " \
                  "and the Edge row says alb: false; remove the region"
          end
          regions.reduce(text) do |current, (name, block)|
            unless Projections::Site::Regions.region?(current, name)
              abort "project_site: #{relative} has no BEGIN/END GENERATED site_cdn #{name} region"
            end

            Projections::Site::Regions.replace(current, name, block)
          end
        end

        # @return [Hash] nothing, after refusing a template named for a project with no edge
        def missing_edge(template)
          abort "project_site: --template names #{template}, but the project declares no Edge rows" if template
          {}
        end

        # @return [String] the template's path, refusing one that does not exist
        def template_source(root, template, relative)
          source = template ? File.expand_path(template) : File.join(root, relative)
          return source if File.file?(source)

          abort "project_site: the template #{relative} does not exist#{" in #{root}" unless template}"
        end

        # @return [String] where the rewritten template goes: its own path, or under `out`
        def destination(source, out, template, relative)
          in_place = template || out.nil?
          in_place ? source : File.join(File.expand_path(out), relative)
        end
      end
    end
  end
end
