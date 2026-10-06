module Hecks
  module Codemod
    # Judges candidate edits to a set of bluebook files one at a time: each is applied, the files
    # are re-booted, and the edit is kept when the booted IR is unchanged and reverted when it is
    # not. A dry run stages every edit in memory and reverts it, still counting a safe one as
    # applied, so the next candidate is judged against the true original state.
    class Sweep
      # What one sweep runs over.
      #
      # - `files`: the bluebook files an edit may land in
      # - `before`: what booting the unedited files answered, which a safe edit leaves alone
      # - `no_match_file`: what a candidate no file's source line matches is reported under
      # - `failure_file`: answers what a reverted edit to a target file is reported under
      # - `reboot`: boots the files as they stand, answering what to compare with `before`
      # - `stage_files`: answers which files an edit to a target file stages
      # - `reason`: words why an edit was reverted, given the error the reboot raised or nil
      Setup = Struct.new(:files, :before, :no_match_file, :failure_file, :reboot, :stage_files, :reason,
                         keyword_init: true)

      # @param runner [Runner] the codemod run, which knows how to apply and label a candidate
      # @param setup [Setup] what to sweep
      # @param results [Hash{Symbol => Array}] the run's `:applied`, `:skipped` and `:clean`
      # @param dry_run [Boolean] whether to leave every file as it was
      def initialize(runner, setup, results, dry_run)
        @runner = runner
        @setup = setup
        @results = results
        @dry_run = dry_run
        @live = setup.files.to_h { |file| [file, File.read(file)] }
        @applied = Hash.new { |hash, file| hash[file] = [] }
      end

      # Judges each candidate, then records what was applied under the file it landed in.
      #
      # @param candidates [Array<Object>] what the codemod found to edit
      # @return [void]
      def call(candidates)
        candidates.each { |candidate| judge(candidate) }
        @applied.each do |file, applied|
          @results[:applied] << { file: file, candidates: applied.map(&@runner.label) }
        end
      end

      private

      def judge(candidate)
        target = @setup.files.find { |file| @runner.apply_candidate.call(@live[file], candidate).last }
        return skip(@setup.no_match_file, "no matching source line", candidate) unless target

        original = edit(target, candidate)
        after, error = Codemod.safely(&@setup.reboot)
        return keep(target, original, candidate) if after == @setup.before

        reject(target, original, error, candidate)
      end

      # Applies the candidate to the target's text and stages it.
      #
      # @return [String] the target's text before the edit
      def edit(target, candidate)
        original = @live[target]
        @live[target] = @runner.apply_candidate.call(original, candidate).first
        stage(target)
        original
      end

      def reject(target, original, error, candidate)
        revert(target, original)
        skip(@setup.failure_file.call(target), @setup.reason.call(error), candidate)
      end

      def keep(target, original, candidate)
        revert(target, original) if @dry_run
        @applied[target] << candidate
      end

      def stage(target)
        @setup.stage_files.call(target).each { |file| Codemod.stage(file, @live[file], dry_run: @dry_run) }
      end

      # Puts the target's original text back and re-boots, so memoized state matches the reverted
      # text.
      def revert(target, original)
        @live[target] = original
        @setup.stage_files.call(target).each { |file| Codemod.unstage(file, @live[file], dry_run: @dry_run) }
        Codemod.safely(&@setup.reboot)
      end

      def skip(file, reason, candidate)
        @results[:skipped] << { file: file, reason: reason, candidates: [@runner.label.call(candidate)] }
      end
    end
  end
end
