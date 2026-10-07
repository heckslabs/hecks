# frozen_string_literal: true

module Hecks
  module Projections
    module Site
      module CmsEditor
        # The editor's icons, drawn once here and emitted as one vector sprite
        # (`src/ui/icons.ts`). Pages and the browser code refer to an icon by name with
        # `<svg><use href="#i-name"/></svg>`, so there is no icon font, no request and no external
        # file. Each is a 24 by 24 outline drawn with the current text colour.
        module Icons
          # Each icon's name and the drawing elements inside its symbol.
          DRAWINGS = {
            "menu"          => '<path d="M4 7h16M4 12h16M4 17h16"/>',
            "close"         => '<path d="M6 6l12 12M18 6L6 18"/>',
            "sun"           => '<circle cx="12" cy="12" r="4"/>' \
                               '<path d="M12 3v2M12 19v2M3 12h2M19 12h2M5.6 5.6L7 7M17 17l1.4 1.4M5.6 18.4L7 17M17 7l1.4-1.4"/>',
            "moon"          => '<path d="M20 14.5A8 8 0 019.5 4 8 8 0 1020 14.5z"/>',
            "sign-out"      => '<path d="M10 4H5v16h5M15 8l4 4-4 4M19 12H9"/>',
            "search"        => '<circle cx="11" cy="11" r="6"/><path d="M16 16l4 4"/>',
            "plus"          => '<path d="M12 5v14M5 12h14"/>',
            "copy"          => '<rect x="9" y="9" width="11" height="11" rx="2"/><path d="M5 15V6a2 2 0 012-2h8"/>',
            "check"         => '<path d="M5 12.5l4.5 4.5L19 7.5"/>',
            "chevron-up"    => '<path d="M6 14l6-6 6 6"/>',
            "chevron-down"  => '<path d="M6 10l6 6 6-6"/>',
            "chevron-right" => '<path d="M10 6l6 6-6 6"/>',
            "arrow-up"      => '<path d="M12 19V5M6 11l6-6 6 6"/>',
            "arrow-down"    => '<path d="M12 5v14M6 13l6 6 6-6"/>',
            "sort"          => '<path d="M8 9l4-4 4 4M8 15l4 4 4-4"/>',
            "trash"         => '<path d="M5 7h14M10 7V4h4v3M7 7l1 13h8l1-13M10 11v6M14 11v6"/>',
            "pencil"        => '<path d="M5 19l1-4L16 5l3 3L9 18l-4 1zM14 7l3 3"/>',
            "bold"          => '<path d="M7 5h6a3.5 3.5 0 010 7H7zM7 12h7a3.5 3.5 0 010 7H7z"/>',
            "italic"        => '<path d="M10 5h8M6 19h8M14 5l-4 14"/>',
            "underline"     => '<path d="M7 5v7a5 5 0 0010 0V5M5 20h14"/>',
            "strike"        => '<path d="M4 12h16M16 7a4 3 0 00-4-2c-2.5 0-4 1.2-4 3s1.5 2.5 4 4 4 2 4 4-1.7 3-4.2 3' \
                               'a5 4 0 01-4.3-2"/>',
            "code"          => '<path d="M9 7l-5 5 5 5M15 7l5 5-5 5"/>',
            "link"          => '<path d="M10 14a4 4 0 005.7 0l3-3a4 4 0 00-5.7-5.7l-1 1' \
                               'M14 10a4 4 0 00-5.7 0l-3 3A4 4 0 0011 18.7l1-1"/>',
            "unlink"        => '<path d="M10 14a4 4 0 005.7 0l3-3a4 4 0 00-5.7-5.7l-1 1' \
                               'M14 10a4 4 0 00-5.7 0l-3 3A4 4 0 0011 18.7l1-1M4 4l16 16"/>',
            "list-bullets"  => '<path d="M9 6h11M9 12h11M9 18h11"/><circle cx="4.5" cy="6" r="1"/>' \
                               '<circle cx="4.5" cy="12" r="1"/><circle cx="4.5" cy="18" r="1"/>',
            "list-numbers"  => '<path d="M10 6h10M10 12h10M10 18h10M4 5l1.5-1v4M4 11.5h3l-3 3h3M4 17.5h3v1.5H5M7 19v1.5H4"/>',
            "indent"        => '<path d="M4 5h16M12 10h8M12 15h8M4 20h16M4 9l3 3-3 3"/>',
            "outdent"       => '<path d="M4 5h16M12 10h8M12 15h8M4 20h16M7 9l-3 3 3 3"/>',
            "align-left"    => '<path d="M4 6h16M4 10h10M4 14h16M4 18h10"/>',
            "align-center"  => '<path d="M4 6h16M7 10h10M4 14h16M7 18h10"/>',
            "align-right"   => '<path d="M4 6h16M10 10h10M4 14h16M10 18h10"/>',
            "align-justify" => '<path d="M4 6h16M4 10h16M4 14h16M4 18h16"/>',
            "image"         => '<rect x="4" y="5" width="16" height="14" rx="2"/><circle cx="9" cy="10" r="1.5"/>' \
                               '<path d="M5 17l5-5 4 4 2-2 3 3"/>',
            "divider"       => '<path d="M4 12h16M8 7h8M8 17h8" stroke-dasharray="0"/>',
            "quote"         => '<path d="M5 17v-4a4 4 0 014-4M13 17v-4a4 4 0 014-4M5 17h4v-4H5M13 17h4v-4h-4"/>',
            "line-break"    => '<path d="M5 6v6a3 3 0 003 3h10M14 11l4 4-4 4"/>',
            "undo"          => '<path d="M9 7L4 12l5 5M4 12h10a5 5 0 010 10"/>',
            "redo"          => '<path d="M15 7l5 5-5 5M20 12H10a5 5 0 000 10"/>',
            "upload"        => '<path d="M12 16V5M7 10l5-5 5 5M5 19h14"/>',
            "alert"         => '<path d="M12 4l9 16H3zM12 10v4M12 17v.5"/>',
            "info"          => '<circle cx="12" cy="12" r="9"/><path d="M12 11v5M12 8v.5"/>',
            "success"       => '<circle cx="12" cy="12" r="9"/><path d="M8 12.5l3 3 5-6"/>',
            "clock"         => '<circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/>',
            "dot"           => '<circle cx="12" cy="12" r="4"/>',
            "inbox"         => '<path d="M4 13l2-8h12l2 8M4 13v6h16v-6M4 13h5l1 2h4l1-2h5"/>',
            "eye"           => '<path d="M2.5 12S6 5.5 12 5.5 21.5 12 21.5 12 18 18.5 12 18.5 2.5 12 2.5 12z"/>' \
                               '<circle cx="12" cy="12" r="3"/>',
            "refresh"       => '<path d="M19 6v5h-5M5 18v-5h5M18.2 10A7 7 0 006 7.5M5.8 14A7 7 0 0018 16.5"/>',
            "external"      => '<path d="M14 4h6v6M20 4l-9 9M18 14v5H5V6h5"/>',
            "phone"         => '<rect x="7" y="3" width="10" height="18" rx="2"/><path d="M11 18h2"/>',
            "tablet"        => '<rect x="5" y="3" width="14" height="18" rx="2"/><path d="M11 18h2"/>',
            "desktop"       => '<rect x="3" y="4" width="18" height="12" rx="2"/><path d="M9 20h6M12 16v4"/>',
            "calendar"      => '<rect x="4" y="5" width="16" height="15" rx="2"/><path d="M4 10h16M9 3v4M15 3v4"/>',
            "arrow-left"    => '<path d="M19 12H5M11 6l-6 6 6 6"/>'
          }.freeze

          module_function

          # @return [String] the symbols as one hidden sprite's body, each with an id `i-<name>`
          def sprite
            DRAWINGS.map { |name, drawing| %(<symbol id="i-#{name}" viewBox="0 0 24 24">#{drawing}</symbol>) }.join("\n")
          end
        end
      end
    end
  end
end
