# frozen_string_literal: true

require_relative "tree"
require_relative "search"
require_relative "declarations"
require_relative "../console_capture"

module Hecks
  module Adapters
    module Codebase
      # What Codebase's `ReadSource`, `Outline` and `Declaration` queries ask of the working tree:
      # reading a file, saying what it declares, and finding where a named construct lives, so a
      # reader never has to leave the launcher for `cat` or `sed`.
      #
      # A construct is found by name, not by pattern, from the scan {Declarations} keeps. The
      # answer is a `path:from-to` range, so one `Declaration` and one `ReadSource` read exactly
      # the block and nothing around it; `show` does both in one call.
      module Reading
        # The most lines `ReadSource` returns when `top` is not named.
        DEFAULT_TOP = 200

        module_function

        # @param args [Hash] the query's arguments: `path`, `from`, `to`, `top`
        # @param tree [Tree] the working tree, already known to be a hecks checkout
        # @return [String] one `line: text` row per line read, then a note when `top` cut it short
        # @raise [ConsoleCapture::Failure] when the path is not a readable text file of the checkout
        def read(args, tree)
          lines = File.readlines(readable(tree, args.fetch(:path)), chomp: true)
          from, upto, shown = window(args, lines.length)
          rows = (from..shown).map { |number| "#{number}: #{lines[number - 1]}" }
          rows << "(#{upto - shown} more lines to #{upto}; ask from=#{shown + 1})" if shown < upto
          rows.join("\n")
        end

        # @return [Array<Integer>] the first line, the last line asked for, and the last line shown
        def window(args, total)
          from = args[:from] || 1
          upto = [args[:to] || total, total].min
          [from, upto, [upto, from + (args[:top] || DEFAULT_TOP) - 1].min]
        end

        # @param args [Hash] the query's argument: `path`
        # @param tree [Tree] the working tree, already known to be a hecks checkout
        # @return [String] one `from-to: kind name` row per declaration, indented by nesting
        # @raise [ConsoleCapture::Failure] when the path is not a readable text file of the checkout
        def outline(args, tree)
          file = args.fetch(:path)
          found = Declarations.outline(file, File.readlines(readable(tree, file), chomp: true))
          found.map { |entry| "#{nesting(found, entry)}#{entry.from}-#{entry.to}: #{entry.label}" }.join("\n")
        end

        # @param args [Hash] the query's arguments: `name`, `kind`, `paths`, `show`
        # @param tree [Tree] the working tree, already known to be a hecks checkout
        # @return [String] one `path:from-to: kind "Name"` row per declaration, the block's text
        #   after each when `show` is set
        # @raise [ConsoleCapture::Failure] when nothing by that name is declared
        def declaration(args, tree)
          found = matching(Declarations.entries(tree, args[:paths]), args)
          raise ConsoleCapture::Failure, "nothing is declared as #{args[:name].inspect}" if found.empty?

          found.map { |entry| args[:show] ? shown(entry, tree) : "#{entry.range}: #{entry.label}" }.join("\n\n")
        end

        # @return [String] the file's absolute path, once it is known to be one to read
        # @raise [ConsoleCapture::Failure] when it leaves the tree, is absent, or holds binary
        def readable(tree, file)
          absolute = File.expand_path(file, tree.root)
          raise ConsoleCapture::Failure, "outside the checkout: #{file}" unless absolute.start_with?("#{tree.root}/")
          raise ConsoleCapture::Failure, "no such file: #{file}" unless File.file?(absolute)
          raise ConsoleCapture::Failure, "not a text file: #{file}" unless Search.text?(tree, tree.relative(absolute))

          absolute
        end

        # @return [Array<Declarations::Entry>] the entries of the name (and kind, when asked)
        def matching(entries, args)
          entries.select { |entry| entry.name == args.fetch(:name) && [nil, entry.kind].include?(args[:kind]) }
        end

        # @return [String] two spaces for each declaration that encloses `entry`
        def nesting(all, entry)
          "  " * all.count { |other| other.from < entry.from && other.to >= entry.to }
        end

        def shown(entry, tree)
          text = File.readlines(tree.path(entry.file), chomp: true)[(entry.from - 1)...entry.to]
          body = text.each_with_index.map { |line, at| "#{entry.from + at}: #{line}" }
          ["#{entry.range}: #{entry.label}", *body].join("\n")
        end
      end
    end
  end
end
