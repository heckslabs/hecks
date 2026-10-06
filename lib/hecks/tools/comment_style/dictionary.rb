# frozen_string_literal: true

require_relative "../../tools"

module Hecks
  module Tools
    module CommentStyle
      # Decides whether a capitalised token is an English word being shouted;
      # anything else keeps its capitals and is reported for a person to look at.
      module Dictionary
        WORDS = "/usr/share/dict/words"

        # Technical vocabulary the system word list lacks.
        EXTRA = %w[
          adversarial allowlist anymore app apps arg args arity async backend backtrace baseline
          boolean bootable bootstrapping bluebook byte callee canonicalized changelog checklist
          checkpoint codebase codemod config database dataset dedupe deduped enqueue evaluator
          filename fixpoint formatting frontend glob grep handover hardcoded hecksagon heredoc held
          hoc hostname idempotency idempotent inline keyword landmine lifecycle lookup mapping
          memoised memoized memoizes metadata metaprogrammed monkeypatch monorepo multi mutex
          namespace noop numeric op ops parameterized params pathname payload plugin postcondition
          pre reachability reentrant refactor regex regexes rekey rekeyed repo restartable retrofit
          reusable roadmap rollup runtime shortcut standalone stringified struct subprocess
          subprocesses subroutine substring superuser symlink sync timestamp tmp tmpl touchpoint
          trickiest triggerable tuple undecoded unsanitized untargeted upsert username webhook
          widget workaround worklist worklists
        ].freeze

        SUFFIXES = [
          ["", ""], ["s", ""], ["es", ""], ["ed", ""], ["d", ""], ["ing", ""], ["ing", "e"], ["ies", "y"],
          ["ied", "y"], ["ly", ""], ["er", ""], ["est", ""], ["ier", "y"], ["ised", "ized"], ["ise", "ize"],
          ["isation", "ization"], ["our", "or"], ["lling", "ling"], ["lled", "led"]
        ].freeze

        module_function

        # Loads and memoizes the system word list, once per process.
        def words
          return @words if defined?(@words)

          @words = File.exist?(WORDS) ? Set.new(File.foreach(WORDS, chomp: true).map(&:downcase)).merge(EXTRA) : nil
        end

        # Checks a capitalized token against the word list, stripped and stemmed.
        # Always true when this machine has no word list to consult.
        def english?(word)
          return true unless words

          bare = word.downcase.delete_suffix("n't").sub(/'.*\z/, "")
          SUFFIXES.any? do |suffix, replacement|
            next false unless bare.end_with?(suffix)

            stem = bare.delete_suffix(suffix) + replacement
            words.include?(stem) || words.include?(stem.sub(/(.)\1\z/, '\1'))
          end
        end
      end
    end
  end
end
