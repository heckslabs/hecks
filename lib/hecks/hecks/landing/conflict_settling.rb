# frozen_string_literal: true

require_relative "bluebook_merge"

module Hecks
  module Landing
    # The merge fixer a landing runs once on a tree whose rebase or merge stopped in conflict: each
    # conflicted bluebook is merged by its declarations ({BluebookMerge}) and staged.
    #
    # It settles only bluebooks, whose declarations can be told apart; a conflict in any other file,
    # a bluebook one side deleted, or a declaration both sides changed is refused by name, and the
    # caller then abandons the rebase or merge as it always has, so nothing is lost.
    class ConflictSettling
      # The index stages of a conflicted path: the common ancestor, ours and theirs.
      STAGES = [1, 2, 3].freeze

      # @param git [Hecks::Adapters::Git] the adapter every git call goes through
      # @param dir [String] the tree in conflict
      def initialize(git, dir)
        @git = git
        @dir = dir
      end

      # @return [Array<String>] the paths in conflict
      def conflicted
        listed = @git.capture("diff", "--name-only", "--diff-filter=U", "-z", chdir: @dir).out
        listed.split("\0").reject(&:empty?)
      end

      # Settles every conflicted path, or stops at the first it cannot.
      #
      # @return [String, nil] why a path could not be settled; nil when every one was
      def refusal
        files = conflicted
        return "no conflicted file to settle" if files.empty?

        files.each do |file|
          why = settle(file)
          return why if why
        end
        nil
      end

      private

      def settle(file)
        return "#{file} is not a bluebook, so it is not merged by declaration" unless file.end_with?(".bluebook")

        base, ours, theirs = STAGES.map { |number| stage(number, file) }
        return "#{file} was deleted on one side" unless ours && theirs

        write(file, BluebookMerge.new(base.to_s, ours, theirs).merged)
      rescue BluebookMerge::Refused => e
        "#{file}: #{e.message}"
      end

      def write(file, text)
        File.write(File.join(@dir, file), text)
        @git.capture("add", "--", file, chdir: @dir)
        nil
      end

      def stage(number, file)
        result = @git.capture("show", ":#{number}:#{file}", chdir: @dir)
        result.ok? ? result.out : nil
      end
    end
  end
end
