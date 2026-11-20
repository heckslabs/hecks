module Hecks
  module Doc
    # Whether a prose region's mentions and supports still resolve against the model as it stands.
    # A command or query mention must be a call the launcher reaches, an aggregate mention an
    # aggregate some booted bluebook declares, an `adr` mention a record under `docs/decisions`; a
    # `doc` or `code_file` support a file in the checkout, a `bluebook_node` an aggregate. Verb,
    # keyword and route mentions and IR element supports are taken as written.
    #
    # @example
    #   ProseCheck.new(root, layout).unresolved(region) # => ["mentions command Landing.land!, …"]
    class ProseCheck
      # @param root [String] the checkout
      # @param layout [#calls, #aggregates] the launcher's reach, as `CliGuides::Layout` answers it
      def initialize(root, layout)
        @root = root
        @layout = layout
      end

      # @param region [ProseMarkers::Region] one prose region
      # @return [Array<String>] why each mention or support does not resolve; empty when all do
      def unresolved(region)
        mentions = region.mentions.reject { |kind, term| mention?(kind, term) }
        supports = region.supports.reject { |kind, target| support?(kind, target) }
        mentions.map { |kind, term| "mentions #{kind} #{term}, which the model no longer has" } +
          supports.map { |kind, target| "rests on #{kind} #{target}, which is gone" }
      end

      private

      # @return [Boolean] whether a mention names something the model has
      def mention?(kind, term)
        case kind
        when "command" then @layout.calls.include?(term)
        when "aggregate" then @layout.aggregates.include?(term)
        when "adr" then !Dir.glob(File.join(@root, "docs/decisions/#{term}-*.md")).empty?
        else true
        end
      end

      # @return [Boolean] whether a support names something that is still there
      def support?(kind, target)
        case kind
        when "doc", "code_file" then File.exist?(File.join(@root, target))
        when "bluebook_node" then @layout.aggregates.include?(target.split("::").last)
        else true
        end
      end
    end
  end
end
