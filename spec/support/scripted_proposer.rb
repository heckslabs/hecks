# frozen_string_literal: true

# A proposer that answers from a script instead of an agent: no model is loaded.
class ScriptedProposer
  # @param script [Hash{Integer => Array<Array(String, String)>}] kind and statement, by exchange
  def initialize(script)
    @script = script
  end

  # @param _exchange [Hash] the exchange asked about
  # @param number [Integer] its number
  # @return [Array<Hash>] the Points proposed for it
  def call(_exchange, number)
    @script.fetch(number, []).map { |kind, statement| { kind: kind, statement: statement } }
  end
end
