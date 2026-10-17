# frozen_string_literal: true

require "json"

module Hecks
  module Projections
    module Site
      class Edge
        # The CloudFront function resource of a `redirect_host` row, and the JavaScript in it.
        #
        # The code is a fixed template (`redirect_host.js.tmpl`) with three values filled in: the
        # canonical host, the alias hosts and the watched paths. A value is never escaped. One
        # outside the strict shape of a lowercase hostname, or of a path made of unreserved
        # characters, is refused, so no value can end a JavaScript string, a YAML block or a
        # CloudFormation expression. The checks refuse such a row when it is read, and `code`
        # refuses again, since it is the last step before the text is written.
        module FunctionCode
          # A lowercase hostname of at least two labels, as the host header is compared after
          # lowercasing.
          HOST = /\A([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}\z/

          # A path of unreserved characters and slashes; no query, no percent escape, no quote.
          PATH = %r{\A/[A-Za-z0-9._~/-]*\z}

          # The longest hostname and path a function takes.
          HOST_LIMIT = 253
          PATH_LIMIT = 200

          TEMPLATE = File.join(__dir__, "redirect_host.js.tmpl")
          PLACEHOLDER = /__(CANONICAL|ALIASES|WATCHED)__/

          module_function

          # @param text [String] a candidate hostname
          # @return [Boolean] whether it may be written into a function
          def host?(text) = text.is_a?(String) && text.size <= HOST_LIMIT && HOST.match?(text)

          # @param text [String] a candidate path
          # @return [Boolean] whether it may be written into a function
          def path?(text) = text.is_a?(String) && text.size <= PATH_LIMIT && PATH.match?(text)

          # @param function [Edge::Function] a `redirect_host` row
          # @return [String] the function's JavaScript, ending in a newline
          # @raise [ArgumentError] when a host or path is outside the strict shapes
          def code(function)
            ensure_safe(function)
            values = { "CANONICAL" => function.host, "ALIASES" => function.alias_list, "WATCHED" => function.path_list }
            File.read(TEMPLATE).gsub(PLACEHOLDER) { JSON.generate(values.fetch(Regexp.last_match(1))) }
          end

          # @param name [String] a function's logical id
          # @return [String] the hyphenated name the function carries, such as `host-redirect`
          def kebab(name) = name.gsub(/([a-z0-9])([A-Z])/, '\1-\2').downcase

          # @param function [Edge::Function] a `redirect_host` row
          # @return [String] the resource, from the left margin, ending in a newline
          def resource(function)
            [
              "#{function.name}:", "  Type: AWS::CloudFront::Function", "  Properties:",
              "    Name: !Sub \"${AWS::StackName}-#{kebab(function.name)}\"", "    AutoPublish: true",
              "    FunctionConfig:", "      Comment: Redirect the watched paths from an alias to the canonical host",
              "      Runtime: cloudfront-js-2.0", "    FunctionCode: |",
              *code(function).each_line.map { |line| line.strip.empty? ? "" : "      #{line.chomp}" }
            ].join("\n") << "\n"
          end

          def ensure_safe(function)
            raise ArgumentError, "EdgeFunction #{function.name} has no path to watch" if function.path_list.empty?

            bad = unsafe_values(function)
            return if bad.empty?

            raise ArgumentError, "EdgeFunction #{function.name} has values outside the hostname and path shapes: " \
                                 "#{bad.map(&:inspect).join(", ")}"
          end

          def unsafe_values(function)
            [function.host, *function.alias_list].reject { |host| host?(host) } +
              function.path_list.reject { |path| path?(path) }
          end
          private_class_method :ensure_safe, :unsafe_values
        end
      end
    end
  end
end
