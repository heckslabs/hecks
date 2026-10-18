module Hecks
  module Composer
    module BoardEdit
      # The text of a command the board adds. The first command of an aggregate creates it, setting
      # the key the aggregate is known by; every later one acts on a record of it. A command with an
      # event says so on a line of its own.
      module CommandText
        module_function

        # @param block [Array<String>] the lines of the aggregate's block, after its declaration
        # @param indent [Integer] how far the aggregate's declaration is indented
        # @param aggregate [String] the aggregate's name
        # @param name [String] the new command's name
        # @param event [String] the event it emits, or an empty string for none
        # @return [Array<String>] the command's lines, indented one step inside the aggregate
        # @raise [Refused] if the aggregate's key cannot be read, for a command that must set it
        def lines(block:, indent:, aggregate:, name:, event:)
          pad = " " * (indent + 2)
          body = acts_on_a_record?(block, indent) ? ["reference_to #{aggregate}"] : creates(block, aggregate)
          inner = [%(goal "Describe #{name}."), *body, (event.empty? ? nil : "emits #{event}")].compact
          ["", %(#{pad}command "#{name}" do), *inner.map { |line| "#{pad}  #{line}" }, "#{pad}end"]
        end

        # @api private
        def acts_on_a_record?(block, indent) = block.any? { |line| line.match?(/\A {#{indent + 2}}command\s+"/) }

        # The attribute and `sets` that give a new record its key.
        # @api private
        def creates(block, aggregate)
          field = block.filter_map { |line| line[/\A\s*identified_by\s+:(\w+)\s*\z/, 1] }.first
          type = field && block.filter_map { |line| line[/\A\s*attribute\s+:#{field},\s*([A-Za-z:]+)/, 1] }.first
          raise Refused, "#{aggregate} has no key the board can read; write its first command in the text" unless type

          ["attribute :#{field}, #{type}", "sets :#{field}"]
        end
      end
    end
  end
end
