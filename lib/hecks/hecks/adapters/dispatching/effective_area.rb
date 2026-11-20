# frozen_string_literal: true

require_relative "../area_overlap"
require_relative "../branch_changes"
require "hecks/hecks/adapters/landing/section_area"

module Hecks
  module Adapters
    class Dispatching
      # The ground a work item holds now: the files its branch changes, once the branch has commits,
      # and the directory or glob it was planned with only before that.
      #
      # A planned area is a guess made before any edit. A branch with commits says what the work
      # item really edits, so those files, plus any file the plan named, are its claim and the
      # directory is let go. Files edited but not yet committed are not seen until a commit holds
      # them; a landing's clash check reads the same committed diff, so the two agree. A file the
      # plan named by its sections (`x.bluebook#Coder`) stays claimed by those sections when the
      # branch changes it, so two items holding different sections of one bluebook stay apart.
      class EffectiveArea
        # @param planned [Array<String>] the area the work item was planned or last rescoped with
        # @param changed [Array<String>] the files its branch changes against main
        # @return [Array<String>] the planned area when the branch changes nothing, else the files
        #   the plan named plus the changed files
        def self.choose(planned, changed)
          return planned if changed.empty?

          named = planned.select { |word| file?(word) }
          sectioned = named.select { |word| Landing::SectionArea.sectioned?(word) }
          held = sectioned.map { |word| Landing::SectionArea.path(word) }
          (named + changed.reject { |file| held.include?(file) }).uniq
        end

        # @param word [String] an area word, which may name sections of its file
        # @return [Boolean] whether it names one file: no glob, and a name with an extension
        def self.file?(word)
          path = Landing::SectionArea.path(word)
          !path.match?(AreaOverlap::WILDCARD) && !File.extname(path).empty?
        end

        # @param repo [String] the checkout whose branches are read
        # @param onto [String] the branch a work item's changes are measured from
        # @param shell [Shell] runs git
        def initialize(repo, onto: "main", shell: Shell.new)
          @changes = BranchChanges.new(repo, onto: onto, shell: shell)
        end

        # @param item [#key, #area] a work item, whose branch is named by its key
        # @return [Array<String>] the area it holds now, its branch's files read by {BranchChanges}
        def call(item) = self.class.choose(item.area, @changes.of(item.key))
      end
    end
  end
end
