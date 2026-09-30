# frozen_string_literal: true

require "open3"
require "shellwords"
require_relative "../../runtime/errors"
require_relative "../cli/child"

module Hecks
  module Adapters
    # The base of the adapters that answer the QA scripts' queries (`SweepTools`,
    # `ClearanceTools`, `AngleTools`, `TargetTools`): each starts one command of
    # `Hecks::QualityControlCli` as its own OS process and answers what it printed.
    #
    # A child, not this process: the commands boot the ledger, fork, spawn and open Postgres
    # connections of their own, and a crash or an `exit` in one must end only that run. The answer
    # is the command's output, unchanged, so the launcher shows the bytes the script prints.
    class QaTool
      # @param aggregate [Object, nil] unused
      # @param settings [Hash] unused
      # @param root [String, nil] the checkout the commands run in; this repository when nil
      def initialize(aggregate: nil, settings: {}, root: nil)
        @root = root || File.expand_path("../../../..", __dir__)
      end

      private

      # Runs one command and answers its output.
      #
      # @param command [String] a key of `QualityControlCli::Child::COMMANDS`
      # @param args [Array<String>] the command's own arguments
      # @param answers [Array<Integer>] the exit statuses that are an answer: a finding, or a
      #   judgment, is one, an operational error is not
      # @return [String] what the command printed, stdout and stderr in order
      # @raise [Runtime::GivenNotMet] with what the command printed, when it ended with another
      #   status
      def run_command(command, *, answers: [0])
        output, status = Open3.capture2e(*QualityControlCli::Child.argv(@root, command, *), chdir: @root)
        return output if answers.include?(status.exitstatus)

        raise Runtime::GivenNotMet, "#{output.strip}\n(#{command} ended with status #{status.exitstatus.inspect})"
      end

      # @param value [Hash, String, nil] a value object's materialized `{ value: "..." }`, or plain
      #   text
      # @return [String, nil] the text, nil when absent
      def plain(value) = value.is_a?(Hash) ? value[:value] : value

      # @param value [Hash, String, nil] words in the command's own flag syntax
      # @return [Array<String>] the words, split as a shell would
      def words(value) = Shellwords.split(plain(value).to_s)
    end
  end
end
