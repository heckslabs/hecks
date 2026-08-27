require "uri"

module Hecks
  module Forms
    # Hand-rolled, on purpose — the repo has no ERB anywhere and no template
    # engine dependency (see docs/command-form-and-query-form-bluebook.md's survey). Every
    # other generator in this codebase (bin/reference's markdown, the IR's own
    # `to_h`) builds output as plain Ruby strings; this does the same for HTML,
    # with exactly one job: nothing that reaches `Escape.html` ever becomes a
    # tag. A feature developer's own domain data — a customer's name, an
    # account number a support rep typed into a form and got wrong — flows
    # through here on every render, so escaping is not optional decoration.
    module Escape
      # Order matters — `&` first, or every escape this method itself just
      # wrote (`&amp;`, `&lt;`, ...) gets re-escaped a second time.
      def self.html(value)
        value.to_s
             .gsub("&", "&amp;")
             .gsub("<", "&lt;")
             .gsub(">", "&gt;")
             .gsub('"', "&quot;")
             .gsub("'", "&#39;")
      end

      # Safe inside a double-quoted HTML attribute specifically — `html`
      # already covers this (it escapes `"`), kept as a named alias so a
      # call site reads "this value fills an attribute" rather than repeating
      # the same escaping and leaving the reader to check they match.
      def self.attr(value) = html(value)

      # L12 (docs/audits/2026-08-10-main-bug-audit.md) — safe as a URL PATH
      # segment or query-string VALUE. `html`/`attr` guard against the
      # value becoming markup, but say nothing about it staying inside the
      # URL syntax position it was placed in: an aggregate's identity is
      # free-form unless its value object declares a `pattern:` (see S3 in
      # the same audit), so `&`, `+`, `?`, `#`, and `/` are all otherwise
      # legal id characters, and each would corrupt an href/Location built
      # by naive interpolation (a stray `&` smuggles a second query
      # parameter, `#` truncates the path at a fragment, `/` splits the
      # path into an extra segment, ...). Percent-encodes via
      # `application/x-www-form-urlencoded` (`+` for space) — the same
      # encoding this directory already uses for a query value elsewhere
      # (query_form_renderer.rb's `quick_links`), now shared here so every
      # id-in-a-link call site uses the one guard instead of remembering
      # it individually. Callers still wrap the ASSEMBLED href/Location in
      # `attr` (or `html`) as usual — this only covers the id's own
      # component, not the surrounding markup.
      def self.url(value) = URI.encode_www_form_component(value.to_s)
    end

    # A tiny attribute-hash -> string helper, shared by every renderer in
    # this directory so `<input ...>` doesn't get hand-assembled five
    # different ways with five different escaping bugs waiting in each.
    # `true` renders as a bare boolean attribute (`required`, not
    # `required="true"`); `nil`/`false` are dropped entirely.
    module Tag
      def self.attrs(pairs)
        pairs.filter_map do |name, value|
          next if value.nil? || value == false
          next name.to_s.tr("_", "-") if value == true

          %(#{name.to_s.tr("_", "-")}="#{Escape.attr(value)}")
        end.join(" ")
      end

      def self.open(name, **pairs)
        rendered = attrs(pairs)
        rendered.empty? ? "<#{name}>" : "<#{name} #{rendered}>"
      end

      def self.void(name, **pairs) = open(name, **pairs) # self-closing tags read the same; HTML5 needs no slash
    end
  end
end
