# frozen_string_literal: true

module Hecks
  module Projections
    module Site
      module RoutesTs
        # The pure TypeScript helpers every `routes.ts` ends with: path matching, then the page
        # switches, search exclusion and draft previews. They are the same text for every table.
        module Helpers
          # Path matching: `stripHtml` and `matchesPath`.
          PATH = <<~'TS'.chomp
            /** Drops a trailing `.html` and a trailing slash, so `/about.html`, `/about/` and `/about` are one path. */
            export function stripHtml(pathname: string): string {
              const bare = pathname.endsWith(".html") ? pathname.slice(0, -".html".length) : pathname;
              return bare.length > 1 && bare.endsWith("/") ? bare.slice(0, -1) : bare;
            }

            function toRegExp(pattern: string): RegExp {
              const source = stripHtml(pattern)
                .split("/")
                .map((part) =>
                  part.startsWith(":")
                    ? "[^/]+"
                    : part
                        .split("*")
                        .map((piece) => piece.replace(/[.+?^${}()|[\]\\]/g, "\\$&"))
                        .join(".*"),
                )
                .join("/");
              return new RegExp("^" + source + "$");
            }

            /**
             * Whether a pathname is one a route pattern describes, with or without `.html`. A `:name` is one
             * segment; a `*` is any run of characters, `/` included, wherever it stands, as in a CDN's path
             * pattern: `/pay/*` matches `/pay/7` and `/admin*` matches `/admin`, `/admin-inbox` and `/admin/x`.
             */
            export function matchesPath(pattern: string, pathname: string): boolean {
              return toRegExp(pattern).test(stripHtml(pathname));
            }
          TS

          # Page switches, search exclusion and draft previews.
          PAGE = <<~'TS'.chomp
            /** Whether a page is on: true for an id no row switches off, and for an id no row names. */
            export function pageIsOn(id: string): boolean {
              return Object.prototype.hasOwnProperty.call(SWITCHES, id) ? SWITCHES[id] : true;
            }

            /** Whether a pathname belongs to a switched-off page, with or without `.html`. */
            export function isOffPath(pathname: string): boolean {
              return MIDDLEWARE.off.paths.some((pattern) => matchesPath(pattern, pathname));
            }

            /** Whether a search engine is kept away from a pathname. */
            export function notForSearch(pathname: string): boolean {
              return NOT_FOR_SEARCH.some((pattern) => matchesPath(pattern, pathname));
            }

            /** The URL that previews a CMS source (`global:<slug>` or `collection:<name>`), under the preview prefix when it is a draft. */
            export function previewUrl(source: string, slug?: string): string {
              const entry = PREVIEWS[source];
              if (entry === undefined) throw new Error(`no route has the source ${source}`);
              let path = entry.path;
              if (path.includes(":")) {
                if (slug === undefined) throw new Error(`${source} previews one entry: pass its slug`);
                path = path.replace(/:[A-Za-z_]\w*/, encodeURIComponent(slug));
              }
              return entry.draft ? MIDDLEWARE.preview.prefix + stripHtml(path) : path;
            }
          TS

          # @return [String] both groups of helpers, as one block of TypeScript
          def self.text = [PATH, PAGE].join("\n\n")
        end
      end
    end
  end
end
