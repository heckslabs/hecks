# frozen_string_literal: true

require_relative "turns"

module Hecks
  module Clients
    module Transcript
      # Pastes of a client's transcript, kept as the turns of one interview: one
      # `Interviews::Interview.Record` per turn, in order. Safe to paste in pieces: the last turn
      # of a chunk is held back, since the next chunk may carry the rest of it, and a turn or a
      # whole chunk already taken adds nothing.
      #
      # Plain Ruby, not an adapter behind a port: what it decides (join, skip, hold back) is the
      # shape of a paste, and the interview is reached only through the `dispatch` it is given.
      # Skipping a recorded exchange belongs in Interviews as a rule of its own, a later bluebook
      # change. A turn is known by its speaker and time, so what is seen lives for one sitting only:
      # a paste after a restart records again, and two turns of one speaker in one second count as
      # one. The interview is the client's and stays local; nothing here is stored by Hecks.
      class Intake
        class Finished < StandardError; end

        # @param dispatch [#call] takes a command name and its attributes, like `dispatch_flat`
        # @param reference [String] the interview's reference
        # @param subject [String] what the interview is about, said on the first turn only
        # @param keeping [String] how the interview is kept, `local` for a client's
        def initialize(dispatch:, reference:, subject:, keeping: "local")
          @dispatch = dispatch
          @opening = { reference: wrap(reference), subject: wrap(subject), keeping: wrap(keeping) }
          @seen = []
          @chunks = []
          @held = nil
        end

        # @param chunk [String] pasted transcript text
        # @return [Integer] how many turns this paste recorded
        def paste(chunk)
          raise Finished, "the transcript was finished" if @finished
          return 0 if @chunks.include?(chunk.to_s.strip)

          @chunks << chunk.to_s.strip
          Transcript.turns(chunk).sum { |turn| take(turn) }
        end

        # Records the turn held back. Calling it again records nothing.
        #
        # @return [Integer] how many turns it recorded
        def finish
          @finished = true
          release
        end

        private

        def take(turn)
          return join(turn) unless turn[:speaker]
          return replace(turn) if @held && key(@held) == key(turn)
          return 0 if @seen.include?(key(turn))

          release.tap { @held = turn }
        end

        def join(turn)
          @held[:text] = "#{@held[:text]} #{turn[:text]}" if @held
          0
        end

        def replace(turn)
          @held = turn if turn[:text].length > @held[:text].length
          0
        end

        def release
          return 0 unless @held

          record(@held)
          @seen << key(@held)
          @held = nil
          1
        end

        def record(turn)
          said = { speaker: wrap(turn[:speaker]), answer: wrap(turn[:text]) }
          @dispatch.call("Interviews::Interview.Record", **@opening, **said)
          @opening = @opening.slice(:reference)
        end

        def key(turn) = [turn[:speaker], turn[:at]]

        def wrap(value) = { value: value }
      end
    end
  end
end
