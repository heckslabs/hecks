# frozen_string_literal: true

require "uri"

module Hecks
  module Projections
    module Site
      module CmsEditor
        # The `Editor` row's `preview`: where a record is shown on the site, as a URL template the
        # editor frames in a side drawer.
        #
        # A template is an `http://` or `https://` address, or a path that starts with one slash,
        # with the placeholders `{key}`, `{kind}`, `{slug}` and `{id}` filled from a record's
        # identity when the page is built. Anything else is refused, so a template cannot name a
        # scheme that runs script (`javascript:`), a host written with credentials, or a
        # placeholder the editor would leave unfilled. A placeholder may not stand in the origin
        # (scheme, host and port), because the content security policy names that origin once, at
        # build time, and allows no other frame.
        module Preview
          # The words a template may put in braces.
          PLACEHOLDERS = %w[key kind slug id].freeze

          # An absolute address: the origin, then whatever follows it.
          ABSOLUTE = %r{\A(?<origin>https?://[^/?#\s]+)(?<rest>.*)\z}m

          module_function

          # @param template [String] the row's `preview`, which may be empty
          # @return [Array<String>] every reason the template is refused; empty when it is usable
          def problems(template)
            return [] if template.empty?

            found = []
            found << "must not hold whitespace" if template.match?(/\s/)
            found.concat(shape_problems(template))
            found.concat(placeholder_problems(template))
            found.map { |problem| "preview #{template.inspect} #{problem}" }
          end

          # @return [String, nil] what the content security policy's `frame-src` names for the
          #   template: its origin, `'self'` for a path, or nil for no preview
          def frame_source(template)
            return nil if template.empty?

            found = ABSOLUTE.match(template)
            found ? found[:origin] : "'self'"
          end

          # @return [Array<String>] the problems with the scheme, the host and the path
          def shape_problems(template)
            found = ABSOLUTE.match(template)
            return path_problems(template) unless found

            origin_problems(found[:origin])
          end

          # @return [Array<String>] the problems with a path template
          def path_problems(template)
            return ["must be an http(s) address or a path that starts with one slash"] unless template.start_with?("/")
            return ["must not start with two slashes, which names another host"] if template.start_with?("//")

            []
          end

          # @return [Array<String>] the problems with the origin of an absolute template
          def origin_problems(origin)
            found = []
            found << "must not name credentials in the address" if origin.include?("@")
            found << "must not hold a placeholder in the scheme, host or port" if origin.include?("{")
            found << "names no host" if !origin.include?("{") && URI.parse(origin).host.to_s.empty?
            found
          rescue URI::InvalidURIError
            ["is not a valid address"]
          end

          # @return [Array<String>] a problem for each unknown placeholder and each stray brace
          def placeholder_problems(template)
            unknown = template.scan(/\{([^{}]*)\}/).flatten.uniq - PLACEHOLDERS
            found = unknown.map do |name|
              "names the placeholder {#{name}}; the placeholders are #{PLACEHOLDERS.map do |word|
                "{#{word}}"
              end.join(", ")}"
            end
            found << "has a brace that is not part of a placeholder" if template.gsub(/\{[^{}]*\}/, "").match?(/[{}]/)
            found
          end
        end
      end
    end
  end
end
