module Hecks
  class Workshop
    # Hecks::Workshop::SystemBrowser
    #
    # Smalltalk-inspired system browser. Prints a navigable tree of all
    # domain elements -- aggregates, attributes, commands, events, policies,
    # queries, specifications, and value objects.
    #
    # Mixed into Session. Uses Unicode box-drawing characters to render a
    # tree structure with proper connectors for last/non-last items.
    #
    #   workshop.browse              # full domain tree
    #   workshop.browse("Account")   # single aggregate
    #
    module SystemBrowser
      # Print a tree view of the domain or a single aggregate.
      #
      # When called without arguments, prints the full domain tree with all
      # aggregates and their sections. When given an aggregate name, prints
      # only that aggregate's tree.
      #
      # @param aggregate_name [String, nil] optional aggregate to browse; nil for all
      # @return [nil]
      def browse(aggregate_name = nil)
        if aggregate_name
          builder = @aggregate_builders[normalize_name(aggregate_name)]
          return puts("Unknown aggregate: #{aggregate_name}") unless builder
          puts browse_aggregate(builder.build, last: true)
        else
          puts "#{@name} Domain"
          aggs = @aggregate_builders.values.map(&:build)
          aggs.each_with_index do |agg, agg_index|
            puts browse_aggregate(agg, last: agg_index == aggs.size - 1)
          end
        end
        nil
      end

      private

      # Render a single aggregate as a tree string with sections.
      #
      # Produces lines with Unicode box-drawing characters. The +last+ parameter
      # controls whether this is the last aggregate in the list, which affects
      # whether a vertical continuation line is drawn.
      #
      # @param agg [DomainModel::Structure::Aggregate] the built aggregate
      # @param last [Boolean] true if this is the last aggregate (uses corner connector)
      # @return [String] multi-line tree representation
      def browse_aggregate(agg, last: false)
        prefix = last ? "  \u2514\u2500\u2500 " : "  \u251c\u2500\u2500 "
        indent = last ? "      " : "  \u2502   "
        lines = ["#{prefix}#{agg.name}"]
        sections = browse_sections(agg)
        sections.each_with_index do |(label, items), section_index|
          connector = section_index == sections.size - 1 ? "\u2514\u2500\u2500 " : "\u251c\u2500\u2500 "
          lines << "#{indent}#{connector}#{label}: #{items}"
        end
        lines.join("\n")
      end

      # Build the list of non-empty sections for an aggregate.
      #
      # Each section is a two-element array of [label, formatted_items_string].
      # Only sections with at least one item are included.
      #
      # @param agg [DomainModel::Structure::Aggregate] the built aggregate
      # @return [Array<Array(String, String)>] list of [label, items] pairs
      def browse_sections(agg)
        sections = []
        if agg.attributes.any?
          sections << ["attributes", agg.attributes.map { |attr| "#{attr.name} (#{attr.type})" }.join(", ")]
        end
        if agg.value_objects.any?
          sections << ["value objects", agg.value_objects.map(&:name).join(", ")]
        end
        if agg.entities.any?
          sections << ["entities", agg.entities.map(&:name).join(", ")]
        end
        if agg.commands.any?
          sections << ["commands", agg.commands.map(&:name).join(", ")]
        end
        if agg.events.any?
          sections << ["events", agg.events.map(&:name).join(", ")]
        end
        if agg.policies.any?
          sections << ["policies", agg.policies.map(&:name).join(", ")]
        end
        if agg.queries.any?
          sections << ["queries", agg.queries.map(&:name).join(", ")]
        end
        if agg.specifications.any?
          sections << ["specifications", agg.specifications.map(&:name).join(", ")]
        end
        sections
      end
    end
  end
end
