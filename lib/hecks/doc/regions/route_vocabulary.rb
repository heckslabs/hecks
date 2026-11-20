require "hecks/codemod"

module Hecks
  module Doc
    module Regions
      # The closed sets a site's route row draws on, as the Site bluebook's `Route` aggregate
      # declares them: one table row per value object that lists its members, with the members in
      # declared order. The Site projection refuses a row naming a value outside these.
      #
      # @example
      #   Hecks::Doc::Regions::RouteVocabulary.render(root)
      #   # => "| closed set | members |\n|---|---|\n| `Kind` | `page`, `endpoint`, ... |"
      module RouteVocabulary
        # The Site bluebook, relative to the checkout.
        SITE = "lib/hecks/site/bluebook/site.bluebook".freeze

        # The table's heading and rule.
        HEAD = "| closed set | members |\n|---|---|".freeze

        module_function

        # @param root [String] the checkout
        # @return [String] the closed sets as a Markdown table
        def render(root)
          rows = closed_sets(root).map { |name, members| "| `#{name}` | #{members.map { |m| "`#{m}`" }.join(", ")} |" }
          ([HEAD] + rows).join("\n")
        end

        # @param root [String] the checkout
        # @return [Array<Array(String, Array<String>)>] each `Route` value object that lists
        #   members, with its members' values, in declared order
        def closed_sets(root)
          route = Codemod.load_bluebook(File.join(root, SITE)).bluebook("Site").aggregate("Route")
          route.value_objects.filter_map do |object|
            members = Array(object.members).map { |member| member.fetch(:value) }
            [object.hecks_name, members] unless members.empty?
          end
        end
      end
    end
  end
end
