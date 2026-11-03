module Hecks
  module DocStaleness
    # The parameter names of a `def`, read from Ripper's `:params` node, and whether any are hidden
    # behind an anonymous splat, a `...` or a named `**` that takes hash-key docs.
    class ParamNames
      # @param params [Array, nil] the `def`'s parameter node
      def initialize(params)
        params = params[1] if params&.first == :paren
        @parts = params&.first == :params ? params.drop(1) : []
      end

      # @return [Array<String>] the names the def takes
      def names = positional + keywords + splats

      # @return [Boolean] whether a tag might name something the list does not show
      def open? = forwarding? || splats_open?

      private

      def forwarding? = rest.is_a?(Array) && rest[0] == :args_forward

      def req = @parts[0].to_a + @parts[3].to_a

      def rest = @parts[2]

      def positional = req.filter_map { |node| node[1] if node[0] == :@ident } + @parts[1].to_a.map { |node| node[0][1] }

      def keywords = @parts[4].to_a.map { |node| node[0][1].chomp(":") }

      def splats = @parts.values_at(2, 5, 6).filter_map { |node| node[1][1] if node.is_a?(Array) && node[1].is_a?(Array) }

      def splats_open?
        @parts.values_at(2, 5, 6).any? { |node| node.is_a?(Array) && (node[1].nil? || node[0] == :kwrest_param) }
      end
    end
  end
end
