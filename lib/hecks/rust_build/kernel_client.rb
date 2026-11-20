# frozen_string_literal: true

require "json"
require "open3"
require_relative "../rust_build"

module Hecks
  module RustBuild
    # A client of the kernel's host protocol (ADR 0189): it runs `rust --serve`, says `hello`, and
    # sends one JSON message per line. While a dispatch runs the kernel may write a `callback`
    # frame asking for a fact it cannot answer itself; the client answers it from the block it was
    # given and the dispatch goes on. A refusal comes back as `{"ok" => false, "error" => ...}`
    # (ADR 0186), never as an exception.
    class KernelClient
      # Raised when the kernel will not speak: it refused the hello or closed its output.
      class Unreachable < StandardError; end

      # @return [Integer] the protocol version both ends agreed on
      attr_reader :protocol

      # @param binary [String] a kernel built for one domain (`cargo build --features <domain>`)
      # @param tables [Hash{String => Hash, Array}] the hello tables the host builds from the IR
      #   (`"needs"`, `"query_needs"`, `"defaults"`, `"run_required"`; see {KernelHello.tables})
      # @param needs [Hash, nil] the `"needs"` table alone (the bench runner's form), merged into
      #   `tables`; an explicit `tables["needs"]` wins
      # @param fill [#call, nil] takes each message before it is sent and answers it with the facts
      #   the host fills itself (see {KernelHello.filler}); with none a message goes as given
      # @yieldparam fact [String] a fact the kernel asked for
      # @yieldparam type [String] the type of the attribute it fills in
      # @yieldparam verb [String] the command that is running
      # @yieldreturn [Object, nil] the value, or nil when the host has none
      # @return [KernelClient] connected, with the protocol agreed
      def self.open(binary, tables: {}, needs: nil, protocols: [1], fill: nil, &answerer)
        client = new(binary, answerer, fill: fill)
        client.hello(tables: { "needs" => needs }.compact.merge(tables), protocols: protocols)
        client
      rescue Unreachable
        client&.close
        raise
      end

      def initialize(binary, answerer, fill: nil)
        @answerer = answerer
        @fill = fill
        @input, @output, @waiter = Open3.popen2(binary, "--serve")
        @input.sync = true
      end

      # Says hello with the tables that are not empty, and records the version the kernel agrees on.
      #
      # @param tables [Hash{String => Hash, Array}] the hello tables, by name
      # @param protocols [Array<Integer>] the versions this end speaks
      # @return [void]
      # @raise [Unreachable] when no version is common to both ends
      def hello(tables:, protocols:)
        hello = tables.reject { |_name, table| table.nil? || table.empty? }.merge("protocols" => protocols)
        hello["callbacks"] = true if @answerer
        answer = call("hello" => hello)
        raise Unreachable, answer["error"] unless answer["ok"]

        @protocol = answer["protocol"]
      end

      # @param verb [String] a qualified command, such as `Pizzas::Order.CreatePizza`
      # @param args [Hash] its arguments
      # @param session [String, nil] a session opened with {#open_session}; the default when nil
      # @param caller [Hash{String => String}] who dispatches, as `"role"` and `"actor_id"`
      # @return [Hash] `{"ok" => true, "events" => [...]}` or `{"ok" => false, "error" => ...}`
      def dispatch(verb, args = {}, session: nil, caller: {})
        message = { "verb" => verb, "args" => args }.merge(caller)
        message["session"] = session if session
        call(message)
      end

      # @return [Hash] `{"ok" => true, "session" => name}`, or a refusal when the name is taken
      def open_session(name) = call("open" => name)

      # @return [Hash] `{"ok" => true}`, or a refusal when no such session is open
      def close_session(name) = call("close" => name)

      # Sends one message, filled first when the client has a fill, and answers the kernel's reply,
      # answering any callbacks on the way. An
      # answerer that raises is answered nil, so the kernel finishes the message and the pipe stays
      # in step, and its error is raised once the reply is read.
      #
      # @param message [Hash] a protocol message
      # @return [Hash] the reply
      # @raise [Unreachable] when the kernel closes its output
      # @raise [StandardError] what the answerer raised while the message ran
      def call(message)
        @input.puts(JSON.generate(@fill ? @fill.call(message) : message))
        failures = []
        frame = JSON.parse(read)
        frame = answered(frame.fetch("callback"), failures) while frame.key?("callback")
        raise failures.first if failures.any?

        frame
      end

      # Ends the connection and waits for the kernel to exit.
      #
      # @return [void]
      def close
        @input.close unless @input.closed?
        @output.close unless @output.closed?
        @waiter.join
      end

      private

      def read
        @output.gets or raise Unreachable, "the kernel closed its output"
      end

      def answered(callback, failures)
        @input.puts(JSON.generate("id" => callback["id"], "answer" => answer_to(callback, failures)))
        JSON.parse(read)
      end

      def answer_to(callback, failures)
        @answerer&.call(callback["fact"], callback["type"], callback["verb"])
      rescue StandardError => e
        failures << e
        nil
      end
    end
  end
end
