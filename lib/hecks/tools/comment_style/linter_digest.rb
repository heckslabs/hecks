# frozen_string_literal: true

require "digest"
require_relative "../../tools"
require_relative "dictionary"

module Hecks
  module Tools
    module CommentStyle
      # One digest of everything besides a file's own text that decides what the linter finds in
      # it: the linter's source, the naming helpers it calls, the word list, the class names under
      # `lib/` it keeps capitalised, and the Ruby whose Ripper parses the file. Facts cached under
      # another digest are never read.
      module LinterDigest
        # The linter's own source, beside this file.
        HERE = File.expand_path("..", __dir__)

        # The files whose code the linter runs.
        SOURCES = [File.join(HERE, "comment_style.rb"), File.join(HERE, "comment_style", "*.rb"),
                   File.expand_path("../../naming.rb", HERE)].freeze

        module_function

        # @return [String] the sha256 of the linter's inputs other than the file it reads
        def current
          Digest::SHA256.hexdigest([RUBY_VERSION, *source_rows, word_list, class_names].join("\n"))
        end

        # @return [Array<String>] each source file's path and the sha of its content, in order
        def source_rows
          SOURCES.flat_map { |glob| Dir[glob] }.sort.map { |path| "#{path} #{Digest::SHA256.file(path).hexdigest}" }
        end

        # @return [String] the word list's size and time, or that this machine has none
        def word_list
          File.exist?(Dictionary::WORDS) ? File.stat(Dictionary::WORDS).then { |s| "#{s.size} #{s.mtime.to_r}" } : "none"
        end

        # @return [String] the class names the caps check keeps, in order
        def class_names = CommentStyle.class_names.sort.join(" ")
      end
    end
  end
end
