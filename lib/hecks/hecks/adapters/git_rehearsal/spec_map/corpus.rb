# frozen_string_literal: true

module Hecks
  module Adapters
    class GitRehearsal
      class SpecMap
        # The spec files of a tree and what each says, read once.
        class Corpus
          # @param root [String] the tree
          def initialize(root)
            @root = root
            @texts = {}
          end

          # @return [Array<String>] every `*_spec.rb` under `spec/`, relative to the root, sorted
          def files = @files ||= Dir.glob("spec/**/*_spec.rb", base: @root).sort

          # @param spec [String] a spec path relative to the root
          # @return [String] its text
          def text(spec) = @texts[spec] ||= File.read(File.join(@root, spec)).scrub
        end
      end
    end
  end
end
