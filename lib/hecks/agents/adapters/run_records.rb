# frozen_string_literal: true

require "hecks/hecks/adapters/started_work"

module Hecks
  module Adapters
    # The `RunRecords` port's adapter for `SubmissionReview`: reads how a run the reviewer cites
    # ended, from its kept record in the Hecks domain's store. A `behaviors` run is an `Operation`,
    # a `model_check` one a `ModelCheckRun`, each found by its run key.
    #
    # It answers the record's own facts: the domain or bluebook directory it ran on, its status as
    # the record says it, and how many scenarios it ran (the per-test lines of a behaviors report,
    # the domains a model check examined). It judges nothing: which runs make a verdict clean is the
    # bluebook's given. It refuses a run it cannot read back, so nothing is counted from prose.
    class RunRecords
      # A cited run has no kept record that ended.
      class Unkept < StandardError; end

      # The aggregate that keeps each kind of evidence, and the field naming what it ran on.
      KEPT = { "behaviors" => ["Operation", :subject], "model_check" => ["ModelCheckRun", :domains] }.freeze

      # A per-test line of a behaviors report: its marker, then the test's description.
      TEST_LINE = /^\s+(ok|FAIL|ERROR)\s/

      # The refusal of a boot that holds no Hecks store: `exe/hecks agents` boots Agents alone.
      NO_STORE = "the Hecks domain is not booted here, so no run record can be read: " \
                 "cite with exe/hecks SubmissionReview.cite!, which boots it"

      # @param registry [Runtime::Registry, nil] whose Hecks store is read
      # @param records [#call, nil] stand-in: takes the kind and the run key, answers the record's
      #   fields as a hash, or nil
      def initialize(registry: nil, records: nil)
        @registry = registry
        @records = records || method(:kept_record)
      end

      # @param kind [Hash, String] `behaviors` or `model_check`
      # @param run [Hash, String] the cited run's key
      # @return [Hash{Symbol => Hash}] `kind:`, `run:`, `subject:`, `status:` and `scenarios:`
      # @raise [Unkept] naming why the run cannot be counted
      def read(kind:, run:, **)
        named = plain(kind)
        key = plain(run)
        record = @records.call(named, key) || raise(Unkept, "no #{named} run is kept under #{key}")
        status = field(record, :status)
        raise Unkept, "the #{named} run #{key} has not ended (#{status})" if status == "requested"

        answer(named, key, record, status)
      end

      private

      def answer(kind, key, record, status)
        { kind: { value: kind }, run: { value: key }, subject: { value: field(record, KEPT.fetch(kind).last) },
          status: { value: status }, scenarios: { value: scenarios(kind, record) } }
      end

      # The scenarios a run ran: the per-test lines of a behaviors report, the domains a model
      # check counted.
      def scenarios(kind, record)
        return field(record, :checked).to_i if kind == "model_check"

        report = [field(record, :output), field(record, :refusal)].join("\n")
        report.scan(TEST_LINE).size
      end

      def kept_record(kind, key)
        aggregate = aggregate_of(kind)
        raise Unkept, NO_STORE unless aggregate

        @registry.repository("Hecks", aggregate).all.find { |record| field(record, :run) == key }
      end

      def aggregate_of(kind)
        name = KEPT.fetch(kind) { raise Unkept, "#{kind} is no kind of evidence" }.first
        bluebook = @registry&.bluebook("Hecks")
        bluebook&.aggregates&.find { |candidate| candidate.hecks_name == name }
      end

      def field(record, name) = StartedWork.value(record, name).to_s

      def plain(argument) = argument.is_a?(Hash) ? argument[:value].to_s : argument.to_s
    end
  end
end
