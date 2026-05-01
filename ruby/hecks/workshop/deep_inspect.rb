# Hecks::Workshop::DeepInspect
#
# Workshop mixin that adds `deep_inspect` for detailed aggregate structure
# display. Uses Navigator to walk the domain IR tree and Renderer to
# format each element into readable output. Shows nested value objects,
# entities, commands with params, events, policies, and all other elements.
#
# Mixed into Workshop alongside Presenter, SystemBrowser, etc.
#
#   workshop.deep_inspect              # all aggregates
#   workshop.deep_inspect("Pizza")     # single aggregate
#
module Hecks
  class Workshop
    module DeepInspect
      # Print a detailed structural breakdown of aggregates.
      #
      # When called without arguments, prints every aggregate with full
      # nesting. When given an aggregate name, prints only that aggregate.
      # Uses Navigator for traversal and Renderer for formatting.
      #
      # @param aggregate_name [String, nil] optional aggregate to inspect
      # @return [nil]
      def deep_inspect(aggregate_name = nil)
        domain = to_domain
        navigator = Navigator.new(domain)
        renderer = Renderer.new
        lines = []

        if aggregate_name
          name = normalize_name(aggregate_name)
          navigator.walk(name) do |element, depth, label|
            line = renderer.render(element, depth: depth, label: label)
            lines << line if line
          end

          if lines.empty?
            puts "Unknown aggregate: #{aggregate_name}"
            return nil
          end
        else
          lines << "#{@name} Domain"
          lines << ""
          navigator.walk_all do |element, depth, label|
            line = renderer.render(element, depth: depth + 1, label: label)
            lines << line if line
          end
        end

        puts lines.join("\n")
        nil
      end
    end
  end
end
