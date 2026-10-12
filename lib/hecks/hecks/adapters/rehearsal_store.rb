# frozen_string_literal: true

require_relative "rehearsal"

module Hecks
  module Adapters
    # The `RehearsalStore` port's adapter: the copy of a domain's data its own world names, which
    # prepares itself when surveyed, runs the mint's audit over itself when examined, and is
    # dropped when it has answered, whichever way it answers.
    #
    # The strategy (`memory` or `postgres`) is the one the subject's `.world` declares with
    # `rehearsed_by`, never an argument. Nothing is written to the subject's own databases: no era
    # is held or named, no table provisioned, no command dispatched. The copy is dropped here, in
    # the same ask that last needs it, so no reaction that fails to arrive can leave one behind.
    class RehearsalStore
      # Accepts the arguments every driven adapter is built with and keeps none of them.
      #
      # @param aggregate [Object, nil] unused
      # @param settings [Hash] unused
      # @param root [String, nil] unused
      def initialize(aggregate: nil, settings: {}, root: nil); end

      # Prepares the copy, loads the domain against it, and reads where its shape stands.
      #
      # @param held [Hash] the record: `domain`, `run` and `pin`
      # @return [Hash] the shape facts, or `booted: false` with why the domain did not load
      # @raise [Rehearsal::Refused] if the pin, the world's declaration or the copy is refused
      def survey(**held)
        Rehearsal.check_pin!(plain(held[:pin]))
        subject = Rehearsal::Subject.open(plain(held[:domain]))
        store = Rehearsal.store_for(subject, plain(held[:run]))
        store.prepare!
        guarded(store) { Rehearsal::Inquiry.new(subject, store).survey }
      rescue Rehearsal::Subject::CannotBoot => e
        { booted: { value: false }, boot_error: { value: e.message } }
      end

      # Runs the mint's audit over the copy, then drops it.
      #
      # @param held [Hash] the record: `domain` and `run`
      # @return [Hash] the edge facts, every refused row, what was not checked, and whether the
      #   copy was dropped
      def examine(**held)
        subject = Rehearsal::Subject.open(plain(held[:domain]))
        store = Rehearsal.store_for(subject, plain(held[:run]))
        facts = guarded(store) { Rehearsal::Inquiry.new(subject, store).examine }
        facts.merge(release(store))
      rescue Rehearsal::Subject::CannotBoot => e
        raise Rehearsal::Refused, e.message
      end

      private

      # Runs the block; when it raises, the copy is dropped before the error goes on.
      def guarded(store)
        yield
      rescue StandardError
        release(store)
        raise
      end

      def release(store)
        store.drop!
        { released: { value: true }, kept: { value: "" } }
      rescue Rehearsal::Refused, StandardError => e
        { released: { value: false }, kept: { value: e.message } }
      end

      def plain(argument) = argument.is_a?(Hash) ? argument[:value] : argument
    end
  end
end
