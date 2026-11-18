# frozen_string_literal: true

require_relative "../area_overlap"
require_relative "../shell"

module Hecks
  module Adapters
    class Dispatching
      # The ground a work item holds now: the files its branch changes, once the branch has commits,
      # and the directory or glob it was planned with only before that.
      #
      # A planned area is a guess made before any edit. A branch with commits says what the work
      # item really edits, so those files, plus any file the plan named, are its claim and the
      # directory is let go. Files edited but not yet committed are not seen until a commit holds
      # them; a landing's clash check reads the same committed diff, so the two agree.
      class EffectiveArea
        # @param planned [Array<String>] the area the work item was planned or last rescoped with
        # @param changed [Array<String>] the files its branch changes against main
        # @return [Array<String>] the planned area when the branch changes nothing, else the files
        #   the plan named plus the changed files
        def self.choose(planned, changed)
          return planned if changed.empty?

          (planned.select { |word| file?(word) } + changed).uniq
        end

        # @param word [String] an area word
        # @return [Boolean] whether it names one file: no glob, and a name with an extension
        def self.file?(word) = !word.match?(AreaOverlap::WILDCARD) && !File.extname(word).empty?

        # @param repo [String] the checkout whose branches are read
        # @param onto [String] the branch a work item's changes are measured from
        # @param shell [Shell] runs git
        def initialize(repo, onto: "main", shell: Shell.new)
          @repo = repo
          @onto = onto
          @shell = shell
          @seen = {}
        end

        # @param item [#key, #area] a work item, whose branch is named by its key
        # @return [Array<String>] the area it holds now
        def call(item) = self.class.choose(item.area, changed(item.key))

        private

        # The same diff a landing reads (`GitLanding::Rivals`), so a rename counts alike in both.
        def changed(branch)
          @seen[branch] ||= begin
            result = @shell.capture("git", "diff", "--no-renames", "--name-only", "-z",
                                    "#{@onto}...refs/heads/#{branch}", chdir: @repo)
            result.ok? ? result.out.split("\0").reject(&:empty?) : []
          end
        end
      end
    end
  end
end
