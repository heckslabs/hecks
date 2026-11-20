# frozen_string_literal: true

require_relative "console_capture"
require_relative "dial_turning/turnables"
require_relative "dial_turning/turned_file"
require_relative "dial_turning/standing"
require_relative "../../adapters/driven/worktree_borrow"
require_relative "../../adapters/driving/resident/paths"

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
      # @param settings [Hash] `directory:` stands in for the domain's directory, and `retire:`
      #   for what asks the checkout's resident to retire
      # @param root [String, nil] unused
      def initialize(aggregate: nil, registry: nil, settings: {}, root: nil)
        @rows = Turnables.of(aggregate).then { |rows| rows.empty? ? Turnables.from_registry(registry) : rows }
        @registry = registry
        @directory = settings[:directory] || self.class.directory
        @retire = settings[:retire] || Driving::Resident::Paths.method(:retire)
      end

      # @param held [Hash] the `Dial` record: `setting` and `becomes`
      # @return [Hash{Symbol => Hash}] `output:` what the setting is now, what it was and the file;
      #   `before:` and `after:` the value it held and holds, in words
      # @raise [ConsoleCapture::Failure] naming a setting that has no row, a value that is not of
      #   its kind or is outside its bounds, or a world that declares no such setting
      def set(**held) = turned(held[:setting], held[:becomes])

      # Sets a probe's setting back to what it was before the turn the probe watched.
      #
      # @param held [Hash] the `Probe` record: `setting` and `before`
      # @return [Hash{Symbol => Hash}] `output:` as {#set} answers it
      # @raise [ConsoleCapture::Failure] as {#set} refuses
      def restore(**held) = turned(held[:setting], held[:before]).slice(:output)

      private

      def turned(setting, becomes)
        told, was, now = turn(row_of(plain(setting).to_s), plain(becomes))
        { output: { value: told }, before: { value: was.to_s }, after: { value: now.to_s } }
      rescue ArgumentError => e
        refuse!(e.message)
      end

      # @return [Array] what the setting is now, what it was and the file it was written to, then
      #   the value it held and the value it holds
      def turn(row, to)
        verb, key = row[:setting].split(".").then { |word, name| [word, name.to_sym] }
        file.locked do
          was = standing(row[:world], verb)
          now = was.merge(key => Turnables.value(row, to))
          [said(row, verb, key, was, now), was[key], now[key]]
        end
      end

      def said(row, verb, key, was, now)
        "#{told(row[:setting], now[key], was[key])}; written to #{write(row[:world], verb, now)}; #{in_force}"
      end

      def told(setting, now, was) = "#{setting} is #{now.inspect}, was #{was.inspect}"

      # A running process keeps the settings it started with, so the checkout's resident is asked
      # to retire: it finishes what it has, and the next command reads the setting as it now is.
      def in_force
        @retire.call(checkout) ? "in force for the next command (the resident restarts)" : "in force for the next command"
      end

      # The checkout whose domain directory the turned file stands in.
      def checkout = File.expand_path("../../..", @directory)

      def row_of(setting)
        known = @rows.map { |row| row[:setting] }
        @rows.find { |row| row[:setting] == setting } ||
          refuse!("#{setting.inspect} is not a setting a turn sets; the settings are #{known.join(", ")}")
      end

      # The verb's settings as the booted world holds them, every local file read.
      def standing(world, verb)
        held = @registry&.world(world)&.for_verb(verb) || {}
        held = held.merge(file.values.fetch([world, verb], {}).transform_keys(&:to_sym))
        held[:adapter] ? held : refuse!("the #{world} world declares no #{verb}, so there is nothing to turn")
      end

      # Sets this verb's line in the file, as the file holds it now, and leaves every other line.
      def write(world, verb, now) = file.replace(world, verb, TurnedFile.line(verb, now))

      def file = (@file ||= TurnedFile.new(@directory))

      def refuse!(message) = raise(ConsoleCapture::Failure, message)

      def plain(argument) = argument.is_a?(Hash) ? argument[:value] : argument
    end
  end
end
