# frozen_string_literal: true

require "open3"
require "hecks/hecks/adapters/area_overlap"
require "hecks/hecks/adapters/landing/section_area"
require "hecks/hecks/adapters/landing/declarations"

module Hecks
  module Adapters
    # Which words of a work item's area name nothing in the checkout. It measures and decides
    # nothing: the `WorkAreas` port's `CheckNames` refuses with the words it returns, and the
    # Tickets bluebook says what a refusal does.
    #
    # A word names something when its path is a file or directory that exists, a file not yet
    # written (it has an extension) in a directory that exists, or a glob that matches a file
    # (one without a `/` matches at any depth, as {AreaOverlap} reads it). The empty path is the
    # whole repository. A word with sections (`x.bluebook#Coder,Brief`, {Landing::SectionArea})
    # also needs each section to be a declaration of that bluebook, read as
    # {Landing::Declarations} cuts it. A work item that adds a directory names the directory that
    # holds it, and one that adds an aggregate names its bluebook with no section. A word that
    # starts with a sibling checkout's name (`switchyard/bluebook`) is read inside that checkout.
    module AreaNames
      # The Tickets world verb that switches the check on (`area_names "WorkAreas", checked: true`).
      VERB = "area_names"

      module_function

      # @param registry [Runtime::Registry, nil] the booted registry whose Tickets world is read
      # @return [Boolean] true only when the world declares `checked: true`
      def checked?(registry)
        declared = registry&.world("Tickets")&.for_verb(VERB)
        [true, "true"].include?(declared && declared[:checked])
      end

      # @param words [Array<String>] area words
      # @param root [String] the checkout the paths are relative to
      # @return [Array<String>] the words that name nothing, in their order
      def unnamed(words, root:) = words.reject { |word| named?(word.to_s.strip, root) }

      # @param word [String] an area word
      # @param root [String] the checkout the path is relative to
      # @return [Boolean] whether the word names a place and every section it claims
      def named?(word, root)
        root, word = sibling(word, root)
        full = File.expand_path(Landing::SectionArea.path(word), root)
        return sections_declared?(word, full) if Landing::SectionArea.sectioned?(word)

        place?(Landing::SectionArea.path(word), full, root)
      end

      # @param dir [String, nil] a directory inside the checkout, the working directory when nil
      # @return [String] the primary checkout's top level, or the directory when it is no checkout
      def root(dir = nil)
        dir ||= Dir.pwd
        common, status = Open3.capture2e("git", "-C", dir, "rev-parse", "--path-format=absolute",
                                         "--git-common-dir")
        status.success? ? File.dirname(common.strip) : dir
      end

      # A word whose first segment is a sibling checkout (a directory with a `.git` beside this
      # checkout, as Switchyard is) names a path in that checkout, which the store also serves.
      #
      # @param word [String] an area word
      # @param root [String] this checkout's top level
      # @return [Array(String, String)] the root the word is read against, and the word within it
      def sibling(word, root)
        head, rest = word.split("/", 2)
        other = File.join(File.dirname(root), head.to_s)
        return [root, word] unless rest && File.exist?(File.join(other, ".git")) && other != root

        [other, rest]
      end

      def place?(path, full, root)
        return glob?(path, root) if path.match?(AreaOverlap::WILDCARD)

        File.exist?(full) || (!File.extname(full).empty? && File.directory?(File.dirname(full)))
      end

      def glob?(path, root)
        pattern = path.include?("/") ? path : "**/#{path}"
        !Dir.glob(pattern, File::FNM_EXTGLOB, base: root).empty?
      end

      def sections_declared?(word, full)
        return false unless File.file?(full)

        names = Landing::Declarations.new(File.read(full)).parts.map(&:name)
        (Landing::SectionArea.sections(word) - names).empty?
      end

      private_class_method :sibling, :place?, :glob?, :sections_declared?
    end
  end
end
