require "digest"

module RuboCop
  module Cop
    module Hecks
      # Flags a script's calling convention outside an adapter or the CLI entry: `OptionParser`,
      # `ARGV`, `exit` and any use of `$stdout`.
      #
      # Arguments, printing and exit belong to an adapter or `exe/`; library code takes values and
      # returns one or raises (ADR 0190). A file in `no_script_io_outside_adapters_baseline.txt`
      # is advisory; the list only shrinks, and a spec fails for a stale entry.
      #
      # @example
      #   OptionParser.new                 # bad
      #   $stdout.puts "done"              # bad
      #   raise Refused, "no such domain"  # good
      class NoScriptIoOutsideAdapters < Base
        MSG = "`%<code>s` is a script's calling convention. Take values and return a value or " \
              "raise; arguments, printing and exit belong in an adapter or `exe/` (ADR 0190).".freeze

        # The files that offend today, one repository-relative path per line.
        BASELINE_PATH = File.expand_path("no_script_io_outside_adapters_baseline.txt", __dir__)

        # @!method script_const?(node)
        def_node_matcher :script_const?, <<~PATTERN
          (const {nil? cbase} {:OptionParser :ARGV :STDOUT})
        PATTERN

        # @!method exit_call?(node)
        def_node_matcher :exit_call?, <<~PATTERN
          (send {nil? (const {nil? cbase} :Kernel)} {:exit :exit!} ...)
        PATTERN

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

        # Flags `OptionParser`, `ARGV` and `STDOUT`.
        #
        # @param node [RuboCop::AST::ConstNode] the constant being visited
        # @return [void]
        def on_const(node)
          flag(node) if script_const?(node)
        end

        # Flags `exit` and `exit!`.
        #
        # @param node [RuboCop::AST::SendNode] the call being visited
        # @return [void]
        def on_send(node)
          flag(node) if exit_call?(node)
        end

        # Flags `$stdout`.
        #
        # @param node [RuboCop::AST::Node] the global variable being visited
        # @return [void]
        def on_gvar(node)
          flag(node) if node.children.first == :$stdout
        end
        alias on_gvasgn on_gvar

        private

        def flag(node)
          return if baselined?

          add_offense(node, message: format(MSG, code: node.source))
        end

        def baselined?
          path = processed_source.file_path.to_s
          self.class.baseline.any? { |entry| path.end_with?("/#{entry}") || path == entry }
        end
      end
    end
  end
end
