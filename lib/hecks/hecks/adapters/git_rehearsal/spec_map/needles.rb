# frozen_string_literal: true

require_relative "constants"

module Hecks
  module Adapters
    class GitRehearsal
      class SpecMap
        # What a spec says when it is about a file: the file's path, how a require spells it, and
        # the constant or domain it declares.
        class Needles
          DOMAIN = /\.(bluebook|hecksagon|world|behaviors)\z/
          DOMAIN_NAME = /^\s*(?:Hecks\.(?:bluebook|hecksagon|world|behaviors)|domain_module|domain)\s+"([^"]+)"/
          NESTING = /^(\s*)(?:class|module)\s+([A-Z][\w:]*)/
          GENERIC = %w[Hecks Adapters Tools Language Framework].freeze

          # @param file [String] the changed file, to read
          # @param path [String] the same file relative to the root
          def initialize(file, path)
            @path = path
            @text = File.exist?(file) ? File.read(file).scrub : ""
          end

          # @return [Boolean] whether there is nothing to look for
          def none? = pattern.nil?

          # @param text [String] a spec's text
          # @return [Boolean] whether the spec is about the file
          def match?(text) = pattern.match?(text)

          private

          def pattern
            return @pattern if defined?(@pattern)

            parts = paths.map { |needle| Regexp.escape(needle) } + names.map { |name| "\\b#{Regexp.escape(name)}\\b" }
            @pattern = parts.empty? ? nil : Regexp.new(parts.join("|"))
          end

          def paths
            bare = @path.delete_prefix("lib/").delete_suffix(".rb")
            [@path, bare, bare.split("/").last(2).join("/")].uniq
          end

          def names = (DOMAIN.match?(@path) ? domain_names : [nesting, *constants]).compact.reject { |name| generic?(name) }.uniq

          def generic?(name) = name.split("::").all? { |segment| GENERIC.include?(segment) }

          # The qualified leaf constants the Ruby file declares.
          def constants = Constants.new(@text).leaves

          def domain_names = @text.scan(DOMAIN_NAME).flatten

          # The innermost class or module of the first chain of nested declarations.
          def nesting
            chain = []
            @text.scan(NESTING) do |indent, name|
              break unless chain.empty? || indent.size == chain.size * 2

              chain << name
            end
            chain.last&.split("::")&.last
          end
        end
      end
    end
  end
end
