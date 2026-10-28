# frozen_string_literal: true

require_relative "tree"
require_relative "search"
require "hecks/composer/outline"

module Hecks
  module Adapters
    module Codebase
      # What `Reading` knows about where things are declared: the `kind "Name"` lines of every
      # declaring file with the extent of each block, kept per checkout and rebuilt only when a
      # declaring file's size or modification time moves.
      #
      # The scan reads the text alone, as the Composer outline does, so it works on a file that
      # does not parse. It also reads the definitions of a Ruby file and the headings of a
      # Markdown file, for `Outline`, which are scanned on demand and never kept.
      module Declarations
        # What a bluebook-family file declares: the constructs the Composer outline jumps to, and
        # the ones it leaves out.
        KINDS = (Composer::Outline::KINDS + %w[read_model lifecycle port adapter]).freeze

        # The files whose declarations are indexed.
        DECLARING = "**/*.{bluebook,hecksagon,behaviors,world,adapter,port}"

        # A declaration line: the keyword, then its name between quotes.
        DECLARATION = /\A(?<indent>\s*)(?<kind>#{KINDS.join("|")})\s+"(?<name>[^"]+)"/

        # A Ruby definition line.
        DEFINITION = %r{\A(?<indent>\s*)(?<kind>class|module|def)\s+(?<name>[\w:.?!=<>\[\]+*/-]+)}

        # A heading of a Markdown file.
        HEADING = /\A(?<hashes>\#{1,6})\s+(?<name>.+)/

        # A line that opens a block closed by a later `end`.
        OPENING = /\bdo\b(\s*\|[^|]*\|)?\s*\z|\A\s*(class|module|def)\s(?!.*\bend\b\s*\z)/

        # A Ruby method written on one line: `def name(args) = body`.
        ENDLESS = /\A\s*def\s+[^\s(]+(\(.*\))?\s=\s/

        # One declaration of the index.
        Entry = Struct.new(:file, :from, :to, :kind, :name, keyword_init: true) do
          def range = "#{file}:#{from}-#{to}"
          def label = KINDS.include?(kind) ? "#{kind} #{name.inspect}" : "#{kind} #{name}"
        end

        @kept = {}

        class << self
          # @return [Hash{String => Hash}] per checkout root, the scan and the stamp it was built from
          attr_reader :kept
        end

        module_function

        # @param tree [Tree] the working tree, already known to be a hecks checkout
        # @param paths [String, nil] files or directories, comma separated; all when nil
        # @return [Array<Entry>] every declaration of those paths, from the kept scan
        def entries(tree, paths = nil)
          all = scanned(tree)
          paths ? within(all, paths) : all
        end

        # @return [Array<Entry>] every declaration of the checkout, rescanned only when a declaring
        #   file's size or modification time differs from the kept scan's
        def scanned(tree)
          files = declaring_files(tree)
          stamp = stamped(tree, files)
          held = Declarations.kept[tree.root]
          return held[:all] if held && held[:stamp] == stamp

          Declarations.kept[tree.root] = { stamp: stamp, all: build(tree, files) }
          Declarations.kept[tree.root][:all]
        end

        # @return [Array<String>] the declaring files below the root, sorted
        def declaring_files(tree)
          Dir.glob(DECLARING, base: tree.root).select { |file| Search.walkable?(file) }.sort
        end

        # @return [Array<Array>] each file with the modification time and size it has now
        def stamped(tree, files) = files.map { |file| [file, *stat(tree, file)] }

        # @param file [String] the file's path, which says what kind of text it holds
        # @param lines [Array<String>] the file's lines
        # @return [Array<Entry>] its declarations, definitions or headings
        def outline(file, lines)
          return headings(file, lines) if file.end_with?(".md")

          scan(file, lines, file.end_with?(".rb") ? DEFINITION : DECLARATION)
        end

        # @return [Array<Entry>] the matches of `pattern` in one file's lines
        def scan(file, lines, pattern = DECLARATION)
          lines.each_with_index.filter_map do |text, index|
            found = text.match(pattern) or next
            Entry.new(file: file, from: index + 1, to: block_end(lines, index, found[:indent].length),
                      kind: found[:kind], name: found[:name])
          end
        end

        # @return [Integer] the line the block opened at `index` closes on: the next `end` at its
        #   own indent, or the line itself when it opens no block
        def block_end(lines, index, indent)
          return index + 1 if !lines[index].match?(OPENING) || lines[index].match?(ENDLESS)

          close = lines[(index + 1)..].to_a.index { |text| text.match?(/\A {#{indent}}end\b/) }
          close ? index + close + 2 : lines.length
        end

        # @return [Array<Entry>] the headings of a Markdown file, each ending where the next of its
        #   level or higher begins
        def headings(file, lines)
          found = lines.each_with_index.filter_map { |text, at| heading(text, at) }
          found.each_with_index.map do |(at, level, name), position|
            stop = found[(position + 1)..].find { |_, other, _| other <= level }
            Entry.new(file: file, from: at + 1, to: stop ? stop[0] : lines.length, kind: "#" * level, name: name)
          end
        end

        # @return [Array, nil] the line index, level and title when `text` is a heading
        def heading(text, index)
          match = text.match(HEADING) or return
          [index, match[:hashes].length, match[:name]]
        end

        # @return [Array<Entry>] the entries whose file is one of `paths`, or below one
        def within(all, paths)
          prefixes = paths.split(",").map { |path| path.delete_prefix("./").chomp("/") }
          all.select { |entry| prefixes.any? { |prefix| entry.file == prefix || entry.file.start_with?("#{prefix}/") } }
        end

        def build(tree, files)
          files.flat_map { |file| scan(file, File.readlines(tree.path(file), chomp: true).map(&:scrub)) }
        end

        def stat(tree, file)
          info = File.stat(tree.path(file))
          [info.mtime.to_i, info.size]
        end
      end
    end
  end
end
