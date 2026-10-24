require "json"
require_relative "../naming"

module Hecks
  module Bulk
    # What one bulk run asks for, read off its `BulkRun` record: the command, the query it runs
    # over, the query's arguments and the mode (ADR 0121).
    Plan = Struct.new(:verb, :over, :arguments, :mode, keyword_init: true) do
      # Reads a plan off a record's held state, as an ask hands it to an adapter.
      #
      # @param held [Hash{Symbol => Object}] the record: `verb`, `over`, `arguments` and `mode`,
      #   each a plain value or a `{ value: }` cell
      # @return [Bulk::Plan] the plan
      def self.from_record(held)
        new(verb: plain(held[:verb]), over: plain(held[:over]), mode: plain(held[:mode]),
            arguments: Array(held[:arguments]).to_h { |pair| [plain(pair[:key]).to_s, plain(pair[:value]).to_s] })
      end

      # The value inside a `{ value: }` cell, or the cell itself.
      #
      # @param cell [Object] a held field
      # @return [Object] its plain value
      def self.plain(cell) = cell.is_a?(Hash) && cell.key?(:value) ? cell[:value] : cell

      # The `Argument` rows a `Request` takes for a query's arguments: a String as itself,
      # anything else as JSON.
      #
      # @param arguments [Hash{Symbol, String => Object}] the query's arguments
      # @return [Array<Hash{Symbol => String}>] one `{ key:, value: }` row per argument
      def self.argument_rows(arguments)
        arguments.map do |key, value|
          { key: key.to_s, value: value.is_a?(String) ? value : JSON.generate(value) }
        end
      end

      # @return [Array(String, String, String)] the query's domain, aggregate and name
      def query_route = Naming.split_verb(over)

      # @return [Boolean] whether every row must be sent or none
      def all_or_nothing? = mode.to_s == "all_or_nothing"

      # The query's arguments, each read as its declared type asks: text for a String
      # argument, JSON for anything else.
      #
      # @param query [Bluebook::Query, nil] the declared query
      # @return [Hash{Symbol => Object}] the arguments the query is asked with
      def query_arguments(query)
        arguments.to_h do |key, text|
          declared = query&.attributes&.find { |attribute| attribute.name.to_s == key }
          [key.to_sym, declared.nil? || declared.type.to_s == "String" ? text : decoded(text)]
        end
      end

      private

      def decoded(text)
        JSON.parse(text, symbolize_names: true)
      rescue JSON::ParserError
        text
      end
    end
  end
end
