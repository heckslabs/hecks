# frozen_string_literal: true

require "json"

# A journal a spec appends to: `gets` blocks, as `tail` does, until a line arrives, and answers nil
# once the journal is closed. It stands in for the file the board's watch follows.
class FakeJournal
  # What a stand-in for the board's stages answers for the tiles the board pushes.
  TILES = {
    fill_tile:  { unknown: "none" },
    plan_tile:  { unknown: "none" },
    train_tile: { name: "Train", state: "ok", count: "1", detail: "d" }
  }.freeze

  # @return [#call] a journal source for the board's watch that follows no file
  def self.source = -> { new }

  def initialize = @lines = Queue.new

  # @param data [Hash] the journal line to append
  def push(data) = @lines << "#{JSON.generate(data)}\n"

  def gets = @lines.pop

  def close = @lines.close
end
