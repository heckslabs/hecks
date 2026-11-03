module Hecks
  module DocStaleness
    # Every constant lib/ defines, by full name, read from `module`, `class` and assignment lines by
    # their nesting.
    class ConstantIndex
      DEFINER = /\A(?<indent>\s*)(?:(?:module|class)\s+(?<scope>[A-Z][\w:]*)|(?<const>[A-Z]\w*)\s*=(?![=~>]))/

      # A cited name: `Hecks` and the constants after it.
      CITED = /\bHecks(?:::[A-Z]\w*)+/

      # A name that stands for any constant in an example.
      STAND_IN = /\A(?:[A-Z]|Foo|Bar|Baz|Thing|Constant|Name)\z/

      # An aggregate a bluebook declares is a constant under `Hecks`, built when the bluebook loads.
      DECLARED = /^\s*(?:aggregate|entity|value_object)\s+"(?<name>[A-Z]\w*)"/

      # @param root [String] the checkout
      def initialize(root)
        @names = {}
        Dir.glob(File.join(root, "{lib,packages/*/lib}/**/*.rb")).each { |path| read(File.read(path, encoding: "UTF-8").scrub) }
        Dir.glob(File.join(root, "lib/**/*.bluebook")).each { |path| declared(File.read(path, encoding: "UTF-8").scrub) }
      end

      # @param name [String] a `Hecks::` name
      # @return [Boolean] whether lib/ defines it, or it is a stand-in such as `Hecks::Foo`
      def known?(name) = @names.key?(name) || name.split("::").last.match?(STAND_IN)

      # @param text [String] a comment
      # @return [Array<String>] the `Hecks::` names it cites that lib/ does not define
      def missing(text) = text.scan(CITED).uniq.reject { |name| known?(name) }

      private

      def declared(text)
        text.scan(DECLARED).flatten.each { |name| mark("Hecks::#{name}") }
      end

      def read(text)
        stack = []
        text.each_line do |line|
          match = DEFINER.match(line) or next
          indent = match[:indent].size
          stack.pop while stack.any? && stack.last[0] >= indent
          record(stack, indent, match)
        end
      end

      def record(stack, indent, match)
        prefix = stack.map(&:last).last.to_s
        if match[:scope]
          full = [prefix, match[:scope]].reject(&:empty?).join("::")
          stack.push([indent, full])
          mark(full)
        else
          mark("#{prefix}::#{match[:const]}")
        end
      end

      def mark(full)
        parts = full.split("::")
        parts.each_index { |index| @names[parts[0..index].join("::")] = true }
      end
    end
  end
end
