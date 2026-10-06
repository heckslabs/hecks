# frozen_string_literal: true

require "json"
require_relative "../../tools"

module Hecks
  module Tools
    module CommentStyle
      # The checked-in list of comment blocks already over `MAX_BLOCK` lines.
      #
      # Keyed by first-line text, not line number, so edits above a block don't break its key.
      module Baseline
        FILE = ".standardize_comments_baseline.json"

        # The checkout this file lives in: the baseline's home when no `root:` is given.
        ROOT = Tools::ROOT

        PATH = File.join(ROOT, FILE)

        module_function

        # The baseline's location inside a checkout.
        #
        # @param root [String] the checkout's root directory
        # @return [String] the baseline file's path
        def path_in(root) = File.join(root, FILE)

        # Reads the baseline from disk.
        def load(path = PATH)
          File.exist?(path) ? JSON.parse(File.read(path, encoding: Encoding::UTF_8)) : {}
        end

        # Writes a baseline in a stable order, so a rewrite shows only real changes in a diff.
        def dump(blocks, path = PATH)
          sorted = blocks.sort.to_h { |file, keys| [file, keys.sort.to_h] }
          File.write(path, "#{JSON.pretty_generate(sorted)}\n")
        end
      end
    end
  end
end
