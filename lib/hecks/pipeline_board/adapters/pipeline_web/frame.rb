# frozen_string_literal: true

module Hecks
  module Adapters
    module PipelineBoard
      # What every page of the board shares, put into each as it is served: the design language
      # (`board.css`, in place of a page's `<!--style-->` mark) and the navigation bar (in place of
      # `<!--nav-->`). A page holds only what is its own, so the pages cannot drift apart in
      # colour or in what they link to. A page with neither mark is served as it is.
      module Frame
        # The shared stylesheet.
        STYLE = File.expand_path("board.css", __dir__)
        # Each page of the board, in the order the bar shows them: its address, its name, and the
        # start of any other address that is the same page (a run's own address is the sessions').
        PAGES = [["/", "Board"], ["/sessions", "Sessions", "/runs/"], ["/plan", "Plan"], ["/agents", "Agents"],
                 ["/ci", "CI"], ["/diagrams", "Diagrams"]].freeze
        # Marks the link of the page being read, by its address.
        CURRENT = "<script>for (const a of document.querySelectorAll(\"nav.pages a\")) " \
                  "if (a.pathname === location.pathname || (a.dataset.also && location.pathname.startsWith(a.dataset.also))) " \
                  "a.setAttribute(\"aria-current\", \"page\");</script>"

        module_function

        # @param html [String] a page as its file holds it
        # @return [String] the page with the shared style and the navigation bar in place
        def apply(html) = html.sub("<!--style-->") { "<style>\n#{File.read(STYLE)}</style>" }.sub("<!--nav-->") { nav }

        # @return [String] the navigation bar, and the script that marks the page being read
        def nav
          links = PAGES.map { |href, name, also| "<a href=\"#{href}\"#{" data-also=\"#{also}\"" if also}>#{name}</a>" }
          "<nav class=\"pages\" aria-label=\"Board pages\">#{links.join}</nav>#{CURRENT}"
        end
      end
    end
  end
end
