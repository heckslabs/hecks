# frozen_string_literal: true

require "json"
require_relative "../rust_build"
require_relative "kernel_input"
require_relative "../runtime/needs"
require_relative "../projector/exporter"

module Hecks
  module RustBuild
    # What a kernel client says at `hello` for a described domain, and how it answers the facts
    # the kernel asks for while a dispatch runs (ADR 0189).
    #
    # The tables come from the registry's canonical IR, every bluebook in it, so a domain needs
    # no generated `ir.json` to be served. Time comes from the registry's clock port, as
    # `Runtime::Needs` reads it in process, so a clock adapter a spec binds is the clock the kernel
    # sees. The kernel answers `now` and `today` from its own clock and never asks for them, so the
    # host fills them into a step that leaves them out, before the step is sent (see {filler}); a
    # callback for either fact is answered from the same port.
    module KernelHello
      # The message key that names a step, mapped to the table its needed facts are listed in.
      STEPS = { "verb" => "needs", "dry_run" => "needs", "validate" => "needs", "query" => "query_needs" }.freeze

      module_function

      # @param registry [Runtime::Registry] the described declarations
      # @return [Hash{String => Hash, Array}] `"defaults"`, `"needs"`, `"query_needs"` and
      #   `"run_required"`, over every bluebook the registry holds
      def tables(registry)
        exported = JSON.parse(JSON.generate(Projector::Exporter.call(registry)))
        exported.each_value.with_object(KernelInput.tables_of(nil)) { |ir, tables| KernelInput.tables_of(ir, tables) }
      end

      # @param registry [Runtime::Registry] where the clock port is bound
      # @return [Proc] the answerer a `KernelClient` takes: `(fact, type, verb)` to the value
      def answerer(registry)
        ->(fact, type, _verb) { answer(registry, fact, type) }
      end

      # @param registry [Runtime::Registry] where the clock port is bound
      # @param tables [Hash] the hello tables, as {tables} builds them
      # @return [Proc] the fill a `KernelClient` takes: a message to the same message with each
      #   clock fact its step needs and leaves out answered from the clock port, read at sending
      def filler(registry, tables)
        ->(message) { filled(registry, tables, message) }
      end

      # @param registry [Runtime::Registry] where the clock port is bound
      # @param tables [Hash] the hello tables
      # @param message [Hash] a protocol message
      # @return [Hash] the message, its arguments holding the answered facts; as given when the
      #   step needs no clock fact the caller left out, or is not a step
      def filled(registry, tables, message)
        key = message["with"].is_a?(Hash) ? "with" : "args"
        args = message[key] || {}
        missing = clock_needs(tables, message).reject { |need| named?(args, need["fact"]) }
        return message if missing.empty?

        message.merge(key => args.merge(missing.to_h { |need| [need["fact"], answer(registry, need["fact"], need["type"])] }))
      end

      # @return [Boolean] whether the caller named the fact, by String or Symbol key
      def named?(args, fact) = args.key?(fact) || args.key?(fact.to_sym)

      # @return [Array<Hash>] the needs of the message's step that the clock answers
      def clock_needs(tables, message)
        name, table = STEPS.find { |step, _table| message.key?(step) }
        return [] unless name

        Array(tables.fetch(table, {})[message[name]]).select { |need| Runtime::Needs::ANSWERS.key?(need["fact"].to_sym) }
      end

      # The answer to one fact, shaped for the argument it fills: a bare Integer for an Integer
      # attribute, else the one-field value object, as `Runtime::Needs.value` shapes it.
      #
      # @param registry [Runtime::Registry] where the clock port is bound
      # @param fact [String] the fact the kernel asked for
      # @param type [String] the type of the argument it fills
      # @return [Integer, Hash{String => Integer}, nil] nil for a fact the host does not answer
      # @raise [Runtime::WiringError] when the clock port is not bound exactly once
      def answer(registry, fact, type)
        reading = Runtime::Needs::ANSWERS[fact.to_s.to_sym] or return nil
        value = reading.call(registry)
        type.to_s == "Integer" ? value : { "value" => value }
      end
    end
  end
end
