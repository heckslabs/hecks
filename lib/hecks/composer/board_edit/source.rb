require_relative "../board"
require_relative "../outline"
require_relative "../workspace"

module Hecks
  module Composer
    module BoardEdit
      # The bluebook text of a staged workspace as lines, with what a board edit needs to change
      # it: where a declaration is, where its block ends (found by indentation, as the bluebooks
      # are laid out), and a way to put a patched file back as one result.
      class Source
        # A bluebook file's path.
        BLUEBOOK_FILE = /\.bluebook\z/

        # The `Hecks.bluebook "Name"` line that declares a bluebook.
        CHAPTER_HEADER = /\A\s*Hecks\.bluebook\s+"/

        # The spaces a line starts with.
        LEADING_SPACES = /\A */

        # @return [Board::Places] where each aggregate, command and policy is declared
        attr_reader :places

        # @param stage [String] a staged directory (see {Workspace.stage})
        def initialize(stage)
          files = Workspace.files(stage)
          @places = Board::Places.new(Outline.call(stage, files))
          @lines = files.grep(BLUEBOOK_FILE).to_h { |file| [file, File.read(File.join(stage, file)).lines.map(&:chomp)] }
        end

        # @param at [Hash] `{file:, line:}` of a declaration
        # @return [Integer] the 0-based index of the `end` that closes it
        # @raise [Refused] if the block has no closing `end` at its own indentation
        def block_end(at)
          lines = @lines.fetch(at[:file])
          start = at[:line] - 1
          pattern = /\A {#{indent_of(lines[start])}}end\b/
          ((start + 1)...lines.size).find { |index| lines[index].match?(pattern) } or
            raise Refused, "cannot find where the block at #{at[:file]}:#{at[:line]} ends"
        end

        # @param at [Hash] `{file:, line:}` of a declaration
        # @return [Integer] how many spaces its line is indented
        def indent(at) = indent_of(@lines.fetch(at[:file])[at[:line] - 1])

        # The file and `end` of the bluebook's own block, where new aggregates and policies go.
        # @return [Hash] `{file:, line:}` of the bluebook header
        # @raise [Refused] if no file declares the bluebook
        def chapter
          file = @lines.keys.sort.find { |path| @lines[path].any? { |line| line.match?(CHAPTER_HEADER) } }
          raise Refused, "no file declares the chapter" unless file

          { file: file, line: @lines[file].index { |line| line.match?(CHAPTER_HEADER) } + 1 }
        end

        # @param file [String] a bluebook path
        # @param from [Integer] first 0-based line to read
        # @param upto [Integer] last 0-based line to read
        # @return [Array<String>] those lines
        def slice(file, from, upto) = @lines.fetch(file)[from..upto]

        # Puts new lines before a line of a file, with a blank line above them unless one is there.
        # @return [Hash] the patched file as `{path:, text:, line:}`
        def insert(file, before, new_lines)
          lines = @lines.fetch(file)
          added = spaced(lines, before, new_lines)
          lines.insert(before, *added)
          patched(file, before + 1 + added.index { |line| !line.strip.empty? }.to_i)
        end

        # Takes lines out of a file, and the blank line above them when there is one.
        # @return [Hash] the patched file as `{path:, text:, line:}`
        def remove(file, from, upto)
          lines = @lines.fetch(file)
          from -= 1 if from.positive? && lines[from - 1].strip.empty?
          lines.slice!(from..upto)
          patched(file, nil)
        end

        private

        def indent_of(line) = line[LEADING_SPACES].size

        # The new lines, without their leading blank line when one is already above the spot.
        def spaced(lines, before, added)
          added.first.to_s.empty? && lines[before - 1].to_s.strip.empty? ? added.drop(1) : added
        end

        def patched(file, line) = { path: file, text: "#{@lines.fetch(file).join("\n")}\n", line: line }
      end
    end
  end
end
