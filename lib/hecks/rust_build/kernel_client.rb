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
      # @param needs [Hash] the `"needs"` table the host builds from the IR (see KernelInput)
      # @yieldparam fact [String] a fact the kernel asked for
      # @yieldparam type [String] the type of the attribute it fills in
      # @yieldparam verb [String] the command that is running
      # @yieldreturn [Object, nil] the value, or nil when the host has none
      # @return [KernelClient] connected, with the protocol agreed
      def self.open(binary, needs: {}, protocols: [1], &answerer)
        client = new(binary, answerer)
        client.hello(needs: needs, protocols: protocols)
        client
      rescue Unreachable
        client&.close
        raise
      end

      def initialize(binary, answerer)
        @answerer = answerer
        @input, @output, @waiter = Open3.popen2(binary, "--serve")
        @input.sync = true
      end

      # Says hello and records the version the kernel agrees on.
      #
      # @return [void]
      # @raise [Unreachable] when no version is common to both ends
      def hello(needs:, protocols:)
        hello = { "protocols" => protocols, "needs" => needs }
        hello["callbacks"] = true if @answerer
        answer = call("hello" => hello)
        raise Unreachable, answer["error"] unless answer["ok"]

        @protocol = answer["protocol"]
      end

      # @param verb [String] a qualified command, such as `Pizzas::Order.CreatePizza`
      # @param args [Hash] its arguments
      # @param session [String, nil] a session opened with {#open_session}; the default when nil
      # @return [Hash] `{"ok" => true, "events" => [...]}` or `{"ok" => false, "error" => ...}`
      def dispatch(verb, args = {}, session: nil)
        message = { "verb" => verb, "args" => args }
        message["session"] = session if session
        call(message)
      end

      # @return [Hash] `{"ok" => true, "session" => name}`, or a refusal when the name is taken
      def open_session(name) = call("open" => name)

      # @return [Hash] `{"ok" => true}`, or a refusal when no such session is open
      def close_session(name) = call("close" => name)

      # Sends one message and answers the kernel's reply, answering any callbacks on the way.
      #
      # @param message [Hash] a protocol message
      # @return [Hash] the reply
      # @raise [Unreachable] when the kernel closes its output
      def call(message)
        @input.puts(JSON.generate(message))
        loop do
          frame = JSON.parse(read)
          return frame unless frame.key?("callback")

          reply(frame.fetch("callback"))
        end
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

      def reply(callback)
        value = @answerer&.call(callback["fact"], callback["type"], callback["verb"])
        @input.puts(JSON.generate("id" => callback["id"], "answer" => value))
      end
    end
  end
end
