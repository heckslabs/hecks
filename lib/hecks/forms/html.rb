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
      # Escapes a value for HTML text content, replacing `&`, `<`, `>`, `"` and `'` with
      # entities so nothing in it becomes a tag.
      #
      # Order matters — `&` first, or every escape this method itself just
      # wrote (`&amp;`, `&lt;`, ...) gets re-escaped a second time.
      #
      # @param value [Object, nil] the value to show, rendered with `to_s`; nil renders as `""`
      # @return [String] the escaped text
      def self.html(value)
        value.to_s
             .gsub("&", "&amp;")
             .gsub("<", "&lt;")
             .gsub(">", "&gt;")
             .gsub('"', "&quot;")
             .gsub("'", "&#39;")
      end

      # Escapes a value for use inside a quoted HTML attribute.
      #
      # Safe inside a double-quoted HTML attribute specifically — `html`
      # already covers this (it escapes `"`), kept as a named alias so a
      # call site reads "this value fills an attribute" rather than repeating
      # the same escaping and leaving the reader to check they match.
      #
      # @param value [Object, nil] the attribute value, rendered with `to_s`; nil renders
      #   as `""`
      # @return [String] the escaped text, without surrounding quotes
      def self.attr(value) = html(value)

      # Percent-encodes a value for use as a query-string value.
      #
      # L12 (docs/audits/2026-08-10-main-bug-audit.md) — safe as a
      # query-string value. `html`/`attr` guard against the value becoming
      # markup, but say nothing about it staying inside the URL syntax
      # position it was placed in: an aggregate's identity is free-form
      # unless its value object declares a `pattern:` (see S3 in the same
      # audit), so `&`, `+`, `?`, `#`, and `/` are all otherwise legal id
      # characters, and each would corrupt an href/Location built by naive
      # interpolation (a stray `&` smuggles a second query parameter, `#`
      # truncates the path at a fragment, `/` splits the path into an
      # extra segment, ...). Percent-encodes via
      # `application/x-www-form-urlencoded` (`+` for space) — correct only
      # for a query-string value (query_form_renderer.rb's `quick_links`,
      # record_renderer.rb's `?to=`). For a URL path segment use `path`
      # below instead — `+` is a literal plus there, not an escaped space,
      # so this method would corrupt any id containing a space. Callers
      # still wrap the assembled href/Location in `attr` (or `html`) as
      # usual — this only covers the id's own component, not the
      # surrounding markup.
      #
      # @param value [Object, nil] the value to encode, rendered with `to_s`
      # @return [String] the `application/x-www-form-urlencoded` form, a space rendered as `+`
      def self.url(value) = URI.encode_www_form_component(value.to_s)

      # Percent-encodes a value for use as one URL path segment.
      #
      # Same guard as `url`, for a URL path segment instead of a
      # query-string value. `encode_www_form_component` renders space as
      # `+`, which is only meaningful inside a query string — in a path
      # segment `+` is a literal plus, so an id like "John Smith" would
      # round-trip to "John+Smith" and 404 against the real id "John
      # Smith". Reuse the same percent-encoding and just correct that one
      # character back to `%20`.
      #
      # @param value [Object, nil] the segment to encode, rendered with `to_s`
      # @return [String] the percent-encoded segment, a space rendered as `%20` and `/` as
      #   `%2F`
      def self.path(value) = URI.encode_www_form_component(value.to_s).gsub("+", "%20")
    end

    # A tiny attribute-hash -> string helper, shared by every renderer in
    # this directory so `<input ...>` doesn't get hand-assembled five
    # different ways with five different escaping bugs waiting in each.
    # `true` renders as a bare boolean attribute (`required`, not
    # `required="true"`); `nil`/`false` are dropped entirely.
    module Tag
      # Renders a Hash of attributes as the text that sits inside an opening tag, escaping
      # every value and spelling an underscored name with hyphens.
      #
      # @param pairs [Hash{Symbol => Object}] attribute values by name; `true`
      #   renders the bare name, nil and `false` drop the attribute, anything else is
      #   rendered with `to_s`
      # @return [String] space-separated attributes, such as `required aria-describedby="x"`;
      #   `""` when every pair is dropped
      def self.attrs(pairs)
        pairs.filter_map do |name, value|
          next if value.nil? || value == false
          next name.to_s.tr("_", "-") if value == true

          %(#{name.to_s.tr('_', '-')}="#{Escape.attr(value)}")
        end.join(" ")
      end

      # Renders an opening tag with its attributes. The tag name is interpolated unescaped,
      # so it must come from code, never from domain data.
      #
      # @param name [String] the element name, such as `"input"`
      # @param pairs [Hash{Symbol => Object}] attributes, rendered as `attrs` renders them
      # @return [String] the opening tag, such as `<input type="text" required>`
      def self.open(name, **pairs)
        rendered = attrs(pairs)
        rendered.empty? ? "<#{name}>" : "<#{name} #{rendered}>"
      end

      # Renders a void element such as `<input>`. A self-closing tag reads the same as an
      # opening one; HTML5 needs no slash.
      #
      # `self.open(...)`, not bare `open(...)` — this `Tag.open` (an HTML tag
      # renderer, right above) shadows Kernel#open safely either way, but the
      # explicit receiver also settles Security/Open's static ambiguity.
      #
      # @param name [String] the element name, such as `"input"`
      # @param pairs [Hash{Symbol => Object}] attributes, rendered as `attrs` renders them
      # @return [String] the tag, identical to what `open` renders
      def self.void(name, **pairs) = self.open(name, **pairs)
    end
  end
end
