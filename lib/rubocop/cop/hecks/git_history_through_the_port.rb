require "digest"

module RuboCop
  module Cop
    module Hecks
      # Flags a `git log` or `git rev-list` call outside an adapter.
      #
      # The pipeline asks the ledger what happened and when; a history read still needed is added
      # to the `Git` port. Adapter folders are skipped: an adapter of another port (Train,
      # Rehearsing) reads the history for its own port, and moving those reads behind `Git`, which
      # has no read for most of them, is the owner's decision. Vendored packages hold the same
      # debt. A file in the baseline list is fully exempt; the cop closes the non-adapter gap only.
      #
      # @example
      #   read("rev-list", "--count", range)    # bad
      #   `git log -1 --format=%H`              # bad
      #   git.oldest_commit_time(older, newer)  # good
      class GitHistoryThroughThePort < Base
        MSG = "`git %<command>s` reads the commit history outside an adapter. Ask the ledger what happened " \
              "and when; if the history itself is needed, add the read to the `Git` port and call it there.".freeze

        # The files that offend today, one repository-relative path per line.
        BASELINE_PATH = File.expand_path("git_history_through_the_port_baseline.txt", __dir__)

        HISTORY_COMMANDS = %w[log rev-list].freeze
        RUNNERS = %i[system exec spawn popen capture2 capture2e capture3].freeze
        # `git`, any options (`-C dir`, `--no-pager`), then the history command.
        COMMAND_LINE = /\bgit(?:\s+-\S+(?:\s+[^\s-]\S*)?)*\s+(log|rev-list)\b/
        # A sibling word that marks `"log"` as git's: the program itself, or an option.
        GIT_WORD = /\A["']?(?:git["']?\z|-)/

        # The repository-relative paths the baseline lists.
        #
        # @return [Array<String>]
        def self.baseline
          lines = File.readlines(BASELINE_PATH, chomp: true).map(&:strip)
          lines.reject { |line| line.empty? || line.start_with?("#") }
        end

        # Folds the baseline into RuboCop's result cache key, so editing the list re-inspects files.
        #
        # @return [String]
        def self.external_dependency_checksum
          Digest::SHA1.hexdigest(File.read(BASELINE_PATH))
        end

        # Flags `"log"` and `"rev-list"` passed as a word of a git command.
        #
        # @param node [RuboCop::AST::StrNode] the string being visited
        # @return [void]
        def on_str(node)
          return unless HISTORY_COMMANDS.include?(node.value)

          words = words_beside(node)
          flag(node, node.value) if node.value == "rev-list" ? words : words&.any? { |word| git_word?(word) }
        end

        # Flags a command line handed to the shell as one string.
        #
        # @param node [RuboCop::AST::SendNode] the call being visited
        # @return [void]
        def on_send(node)
          return unless RUNNERS.include?(node.method_name)

          node.arguments.each { |argument| flag_line(argument) if argument.type?(:str, :dstr) }
        end

        # Flags a backtick or `%x` command.
        #
        # @param node [RuboCop::AST::StrNode] the command literal being visited
        # @return [void]
        def on_xstr(node)
          flag_line(node)
        end

        private

        # The other words of the call or array literal a string is a word of, nil when in neither.
        def words_beside(node)
          parent = node.parent
          return unless parent
          return parent.children - [node] if parent.array_type?

          parent.arguments - [node] if parent.call_type? && parent.arguments.include?(node)
        end

        def git_word?(word)
          word.type?(:str, :dstr) && word.source.match?(GIT_WORD)
        end

        def flag_line(node)
          command = node.source[COMMAND_LINE, 1]
          flag(node, command) if command
        end

        def flag(node, command)
          return if baselined?

          add_offense(node, message: format(MSG, command: command))
        end

        def baselined?
          path = processed_source.file_path.to_s
          self.class.baseline.any? { |entry| path.end_with?("/#{entry}") || path == entry }
        end
      end
    end
  end
end
