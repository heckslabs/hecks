# frozen_string_literal: true

module Hecks
  module Adapters
    module PipelineBoard
      # What every page of the board shares, put into each as it is served: the design language
      # (`board.css`, in place of a page's `<!--style-->` mark), Una (the mark that waiting is
      # drawn with) and, for a page that carries a `<!--nav-->` mark, the bar across its top. A
      # page holds only what is its own, so the pages cannot drift apart in colour, in width or in
      # what they link to. A fragment with no `<body>` is served with its style and nothing more.
      module Frame
        # The shared stylesheet.
        STYLE = File.expand_path("board.css", __dir__)
        # Una, the Embryonaut mark: one shape, drawn in the colour the stylesheet gives it.
        UNA = File.expand_path("una.svg", __dir__)
        # The group holding Una's shape in that file, and the colour the file bakes into it.
        SHAPE = %r{<g .*</g>}m
        BAKED_FILL = /fill="#\h+"/
        # Each page of the board, in the order the bar shows them: its address, its name, and the
        # start of any other address that is the same page (a run's own address is the sessions').
        PAGES = [["/", "Board"], ["/sessions", "Sessions", "/runs/"], ["/plan", "Plan"], ["/agents", "Agents"],
                 ["/events", "Events", "/trains/"], ["/ci", "CI"], ["/diagrams", "Wiring"], ["/settings", "Settings"]].freeze
        # Una drawn by name, as a page writes her.
        DRAWN = "<svg class=\"una\" viewBox=\"0 0 392 420\" aria-hidden=\"true\"><use href=\"#una\"/></svg>"
        # `una(text, big)` answers the element a page shows while it waits: Una turning, small
        # beside the words or large above them. The second script marks the page being read.
        SCRIPT = "<script>window.una = function (text, big) { const el = document.createElement(\"div\"); " \
                 "el.className = \"una-wait\" + (big ? \" big\" : \"\"); el.setAttribute(\"role\", \"status\"); " \
                 "el.innerHTML = '#{DRAWN}'; if (text) el.append(text); return el; };</script>".freeze
        CURRENT = "<script>for (const a of document.querySelectorAll(\"nav.pages a\")) " \
                  "if (a.pathname === location.pathname || (a.dataset.also && location.pathname.startsWith(a.dataset.also))) " \
                  "a.setAttribute(\"aria-current\", \"page\");</script>"
        # The button a narrow screen shows in place of the links: three bars, and the page's name.
        MENU = "<button class=\"menu\" type=\"button\" aria-expanded=\"false\" aria-controls=\"pages\">" \
               "<span class=\"bars\" aria-hidden=\"true\"><i></i><i></i><i></i></span><span class=\"here\">Menu</span></button>"
        # Opens and closes the links under the bar, names the page on the button, and closes them
        # on Escape or a press anywhere else.
        MENU_SCRIPT = "<script>(function () { const bar = document.querySelector(\".topbar\"); " \
                      "const menu = bar.querySelector(\".menu\"); " \
                      "const here = bar.querySelector(\"nav.pages a[aria-current]\"); " \
                      "if (here) menu.querySelector(\".here\").textContent = here.textContent; " \
                      "const set = (open) => { bar.classList.toggle(\"open\", open); " \
                      "menu.setAttribute(\"aria-expanded\", String(open)); }; " \
                      "menu.addEventListener(\"click\", () => set(!bar.classList.contains(\"open\"))); " \
                      "addEventListener(\"keydown\", (e) => { if (e.key === \"Escape\") set(false); }); " \
                      "addEventListener(\"click\", (e) => { if (!bar.contains(e.target)) set(false); }); })();</script>"

        module_function

        # @param html [String] a page as its file holds it
        # @return [String] the page with the shared style, Una and its bar in place
        def apply(html)
          styled = html.sub("<!--style-->") { "<style>\n#{File.read(STYLE)}</style>" }
          return styled unless styled.include?("<body>")

          top = styled.include?("<!--nav-->") ? bar : ""
          styled.sub("<!--nav-->", "").sub("<body>") { "<body>#{una}#{top}" }
        end

        # @return [String] Una as a shape pages draw by name, and the script that draws her waiting
        def una
          shape = File.read(UNA)[SHAPE].sub(BAKED_FILL, "")
          "<svg style=\"position:absolute;width:0;height:0\" aria-hidden=\"true\"><symbol id=\"una\" viewBox=\"0 0 392 420\">" \
            "#{shape}</symbol></svg>#{SCRIPT}"
        end

        # @return [String] the bar across the top of a page: Una and the name, then the pages, which
        #   a narrow screen folds behind a menu button
        def bar
          "<div class=\"topbar\"><div class=\"in\"><a class=\"brand\" href=\"/\">#{DRAWN}Pipeline</a>#{MENU}#{nav}</div></div>"
        end

        # @return [String] the links to every page, and the scripts that mark the page being read
        #   and work the menu button
        def nav
          links = PAGES.map { |href, name, also| "<a href=\"#{href}\"#{" data-also=\"#{also}\"" if also}>#{name}</a>" }
          "<nav class=\"pages\" id=\"pages\" aria-label=\"Board pages\">#{links.join}</nav>#{CURRENT}#{MENU_SCRIPT}"
        end
      end
    end
  end
end
