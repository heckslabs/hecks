require "uri"

module Hecks
  module Forms
    # HTML, URL-query and URL-path escaping for values that come from domain data.
    # Nothing that reaches `Escape.html` becomes a tag.
    module Escape
      # Escapes a value for HTML text content, replacing `&`, `<`, `>`, `"` and `'` with
      # entities so nothing in it becomes a tag.
      #
      # `&` is replaced first so the entities written here are not escaped again.
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
      # Safe inside a double-quoted attribute; an alias of `html` so call sites say what
      # the value fills.
      #
      # @param value [Object, nil] the attribute value, rendered with `to_s`; nil renders
      #   as `""`
      # @return [String] the escaped text, without surrounding quotes
      def self.attr(value) = html(value)

      # Percent-encodes a value for use as a query-string value.
      #
      # Aggregate ids are free-form, so `&`, `#` and `/` must not reach a URL raw. Correct
      # for a query-string value only; use `path` for a path segment. Callers still wrap
      # the assembled href in `attr`.
      #
      # @param value [Object, nil] the value to encode, rendered with `to_s`
      # @return [String] the `application/x-www-form-urlencoded` form, a space rendered as `+`
      def self.url(value) = URI.encode_www_form_component(value.to_s)

      # Percent-encodes a value for use as one URL path segment.
      #
      # Like `url`, but a space becomes `%20`: `+` is a literal plus in a path segment.
      #
      # @param value [Object, nil] the segment to encode, rendered with `to_s`
      # @return [String] the percent-encoded segment, a space rendered as `%20` and `/` as
      #   `%2F`
      def self.path(value) = URI.encode_www_form_component(value.to_s).gsub("+", "%20")
    end

    # Attribute-hash to string helper shared by the form renderers.
    # `true` renders a bare boolean attribute; `nil` and `false` are dropped.
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

          %(#{name.to_s.tr("_", "-")}="#{Escape.attr(value)}")
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
      # The explicit `self.open` receiver keeps Security/Open from flagging Kernel#open.
      #
      # @param name [String] the element name, such as `"input"`
      # @param pairs [Hash{Symbol => Object}] attributes, rendered as `attrs` renders them
      # @return [String] the tag, identical to what `open` renders
      def self.void(name, **pairs) = self.open(name, **pairs)
    end
  end
end
