module Hecks
  module Projections
    module Glossary
      module Html
        # Reads the Markdown subset the glossary projector emits into `Html::Block`s.
        module Parser
          module_function

          # Parses the Markdown subset the glossary projector emits into blocks.
          def parse(markdown)
            lines  = markdown.lines.map(&:chomp)
            blocks = []
            index  = 0
            while index < lines.size
              block, index = read_block(lines, index)
              blocks << block if block
            end
            blocks
          end

          # The block that starts at `index` (nil for a blank line), and the index just past it.
          def read_block(lines, index)
            line = lines[index]
            return [nil, index + 1] if line.strip.empty?

            case line
            when /\A```mermaid/ then fence(lines, index)
            when /\A(\#{1,3}) (.+)\z/ then [heading(Regexp.last_match), index + 1]
            when /\A> / then [Block.new(type: :quote, text: line[2..]), index + 1]
            when /\A- / then list(lines, index)
            else paragraph(lines, index)
            end
          end

          def heading(match) = Block.new(type: :heading, text: match[2], level: match[1].size)

          def list(lines, index)
            items, index = run(lines, index) { |text| text.start_with?("- ") }
            [Block.new(type: :list, items: items.map { |item| item[2..] }), index]
          end

          def paragraph(lines, index)
            para, index = run(lines, index) { |text| !text.strip.empty? }
            [Block.new(type: :paragraph, text: para.join(" ")), index]
          end

          # The mermaid block opened at `index`, and the line index just past its closing fence.
          def fence(lines, index)
            close = ((index + 1)...lines.size).find { |at| lines[at] == "```" } || lines.size
            [Block.new(type: :mermaid, text: lines[(index + 1)...close].join("\n")), close + 1]
          end

          # The consecutive lines from `index` that satisfy the block, and the index past them.
          def run(lines, index)
            taken = []
            while index < lines.size && yield(lines[index])
              taken << lines[index]
              index += 1
            end
            [taken, index]
          end
        end
      end
    end
  end
end
