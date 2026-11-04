# frozen_string_literal: true

module Hecks
  # Reads the `CheckConclusion` rows of the Vocabulary bluebook. Every adapter that asks whether a
  # GitHub conclusion passed goes through here, so the words live in one declared table.
  module CheckConclusion
    # @param conclusion [String, nil] the conclusion GitHub reports; nil is not yet concluded
    # @return [Boolean] whether a check with this conclusion stands in for a passed one
    def self.certifies?(conclusion) = flag?(conclusion, "certifies")

    # @param conclusion [String, nil] the conclusion GitHub reports
    # @return [Boolean] whether a run or a list of checks with this conclusion is no failure
    def self.clean?(conclusion) = flag?(conclusion, "clean")

    # @param conclusion [String, nil] the conclusion of a spec job
    # @return [Boolean] whether the job ran its specs and they passed
    def self.evidence?(conclusion) = flag?(conclusion, "evidence")

    # @param conclusion [String, nil] the conclusion of a job
    # @return [Boolean] whether the job did not run to an end, so it is no verdict on the specs
    def self.unfinished?(conclusion) = flag?(conclusion, "unfinished")

    # @param conclusion [String, nil] a conclusion; nil reads as the empty name
    # @param name [String] the flag column to read
    # @return [Boolean] whether the row for this conclusion carries `yes` in that column
    def self.flag?(conclusion, name)
      row = Hecks::Vocabulary.rows("CheckConclusion").find { |candidate| candidate["name"] == conclusion.to_s }
      !row.nil? && row[name] == "yes"
    end
    private_class_method :flag?
  end
end
