require "ripper"
require_relative "param_names"

module Hecks
  module DocStaleness
    # The `@param` tags of a Ruby file whose names are not among the parameters of the `def`
    # under them. A tag that documents a key of `**opts`, or a def with an anonymous splat, is left.
    class YardParams
      # One `def`: its line and the names it takes. `open` is true when a name may be hidden.
      Signature = Struct.new(:line, :names, :open)

      # A tag name that documents a hash key (`opts.color`, `opts[:color]`) rather than a parameter.
      HASH_KEY = /[.\[<{:]/
      SIGILS = /\A[*&:]+/

      TAG = /@param\s+(?:\[[^\]]*\]\s+)?(?<name>[^\s\[]+)/

      # @param text [String] Ruby source
      # @param comments [Array<Array(Integer, String)>] its comments, as `RubyComments.of`
      def initialize(text, comments)
        @sexp = Ripper.sexp(text)
        @comments = comments.to_h
      end

      # @return [Array<Array(Integer, String)>] the line and name of each tag naming no parameter
      def stale
        return [] unless @sexp

        signatures(@sexp).flat_map { |signature| unknown(signature) }
      end

      private

      def unknown(signature)
        return [] if signature.open

        tags(signature.line).reject { |(_, name)| signature.names.include?(name) }
      end

      # The tags of the comment lines directly above a def.
      def tags(line)
        first = line
        first -= 1 while @comments.key?(first - 1)
        (first...line).filter_map do |at|
          match = TAG.match(@comments[at])
          name = match && bare(match[:name])
          [at, name] if name
        end
      end

      def bare(name)
        return nil if name.match?(HASH_KEY) && !name.end_with?(":")

        name.sub(SIGILS, "").chomp(":")
      end

      def signatures(node, found = [])
        return found unless node.is_a?(Array)

        found << signature(node) if %i[def defs].include?(node[0])
        node.each { |child| signatures(child, found) }
        found
      end

      def signature(node)
        ident, params = node[0] == :def ? [node[1], node[2]] : [node[3], node[4]]
        parsed = ParamNames.new(params)
        Signature.new(ident[2][0], parsed.names, parsed.open?)
      end
    end
  end
end
