require_relative "html"

module Hecks
  module Forms
    # The home page: every exposed chapter, every aggregate on it — the
    # entry point into what would otherwise be a URL you'd have to already
    # know. `chapters` is `{domain_name => Bluebook::Chapter}`, in `expose`
    # order (see `Forms::Config` in forms.rb).
    module IndexRenderer
      # Renders the home page body: one section per exposed chapter, each linking to its
      # aggregates.
      #
      # @param chapters [Hash{String => Bluebook::Chapter}] the loaded chapters by domain
      #   name, in `expose` order
      # @return [String] the HTML page body; only the heading when `chapters` is empty
      def self.render(chapters)
        sections = chapters.map { |name, chapter| chapter_section(name, chapter) }
        <<~HTML
          <h1>Exposed domains</h1>
          #{sections.join}
        HTML
      end

      # Renders one chapter's section: its name, its vision as a badge when it declares one,
      # and a link per aggregate showing how many commands and queries it has.
      #
      # @param name [String] the domain name, used as the heading and the first path segment
      # @param chapter [Bluebook::Chapter] the loaded chapter
      # @return [String] HTML for the section's heading and aggregate list
      def self.chapter_section(name, chapter)
        items = chapter.aggregates.map do |aggregate|
          counts = "#{aggregate.commands.size} command#{'s' unless aggregate.commands.size == 1}, " \
                   "#{aggregate.queries.size} quer#{aggregate.queries.size == 1 ? 'y' : 'ies'}"
          <<~HTML
            <li><a href="/#{Escape.attr(name)}/#{Escape.attr(aggregate.hecks_name)}.html">
              <span>#{Escape.html(aggregate.hecks_name)}</span><span class="kind">#{Escape.html(counts)}</span>
            </a></li>
          HTML
        end
        <<~HTML
          <h2>#{Escape.html(name)}#{%( <span class="badge">#{Escape.html(chapter.vision)}</span>) if chapter.vision}</h2>
          <ul class="verb-list">#{items.join}</ul>
        HTML
      end
    end
  end
end
