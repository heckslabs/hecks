require_relative "html"

module Hecksagain
  module Presentation
    # The home page: every exposed chapter, every aggregate on it — the
    # entry point into what would otherwise be a URL you'd have to already
    # know. `chapters` is `{domain_name => IR::Bluebook}`, in `expose` order
    # (see config.rb).
    module IndexRenderer
      def self.render(chapters)
        sections = chapters.map { |name, chapter| chapter_section(name, chapter) }
        <<~HTML
          <h1>Exposed domains</h1>
          #{sections.join}
        HTML
      end

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
          <h2>#{Escape.html(name)}#{chapter.vision ? %( <span class="badge">#{Escape.html(chapter.vision)}</span>) : ''}</h2>
          <ul class="verb-list">#{items.join}</ul>
        HTML
      end
    end
  end
end
