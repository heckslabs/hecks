# frozen_string_literal: true

require_relative "console_capture"
require_relative "dial_turning/turnables"
require_relative "dial_turning/turned_file"
require_relative "dial_turning/standing"
require_relative "../../adapters/driven/worktree_borrow"

module Hecks
  module Adapters
    # The `Turning` port's adapter for `Dial.Turn`, through its `Set` ask: sets one setting the
    # `Turnable` rows allow, to a value inside its row's bounds, by writing the checkout's
    # gitignored `turned.local.world`. A world merges a verb whole, so the line written carries
    # every key the verb has now with the one key changed. It touches that one file, no ledger and
    # no git state. A linked worktree that keeps no local file writes the main checkout's, the one
    # it reads.
    class DialTurning
      # The Hecks domain's own directory, where its world files stand.
      DOMAIN = File.expand_path("..", __dir__)

      # @return [String] where the turned file is: this checkout's copy of the domain's directory,
      #   or the main checkout's when this is a linked worktree that borrows its local files
      def self.directory = WorktreeBorrow.directory(DOMAIN, env: ENV) || DOMAIN

      # @param aggregate [Bluebook::Aggregate, nil] `Dial`, whose `Turnable` rows say what is set
      # @param registry [Runtime::Registry, nil] the booted registry whose worlds are read
      # @param settings [Hash] `directory:` stands in for the domain's directory
      # @param root [String, nil] unused
      def initialize(aggregate: nil, registry: nil, settings: {}, root: nil)
        @rows = Turnables.of(aggregate)
        @registry = registry
        @directory = settings[:directory] || self.class.directory
      end

      # @param held [Hash] the `Dial` record: `setting` and `becomes`
      # @return [Hash{Symbol => Hash}] `output:` what the setting is now, what it was and the file
      # @raise [ConsoleCapture::Failure] naming a setting that has no row, a value that is not of
      #   its kind or is outside its bounds, or a world that declares no such setting
      def set(**held)
        { output: { value: turn(row_of(plain(held[:setting]).to_s), plain(held[:becomes])) } }
      rescue ArgumentError => e
        refuse!(e.message)
      end

      private

      # @return [String] what the setting is now, what it was and the file it was written to
      def turn(row, to)
        verb, key = row[:setting].split(".").then { |word, name| [word, name.to_sym] }
        was = standing(row[:world], verb)
        now = was.merge(key => Turnables.value(row, to))
        "#{row[:setting]} is #{now[key].inspect}, was #{was[key].inspect}; written to #{write(row[:world], verb, now)}"
      end

      def row_of(setting)
        known = @rows.map { |row| row[:setting] }
        @rows.find { |row| row[:setting] == setting } ||
          refuse!("#{setting.inspect} is not a setting a turn sets; the settings are #{known.join(", ")}")
      end

      # The verb's settings as the booted world holds them, every local file read.
      def standing(world, verb)
        held = @registry&.world(world)&.for_verb(verb) || {}
        held[:adapter] ? held : refuse!("the #{world} world declares no #{verb}, so there is nothing to turn")
      end

      # Writes every verb the file already holds as it stands, and this one as it now is.
      def write(world, verb, now)
        file = TurnedFile.new(@directory)
        turned = [world, verb]
        lines = (file.turned + [turned]).uniq.map do |pair|
          [pair.first, TurnedFile.line(pair.last, pair == turned ? now : standing(*pair))]
        end
        file.write(lines.group_by(&:first).transform_values { |pairs| pairs.map(&:last) })
      end

      def refuse!(message) = raise(ConsoleCapture::Failure, message)

      def plain(argument) = argument.is_a?(Hash) ? argument[:value] : argument
    end
  end
end
