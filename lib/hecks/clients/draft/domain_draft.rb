# frozen_string_literal: true

module Hecks
  module Clients
    module Draft
      # Drafts a client's domain as their interview goes: for each turn an agent (the proposer)
      # puts thing, action and event Points forward citing that turn, the owner accepts or rejects
      # them, and the accepted Points are projected as bluebook text quoting the client.
      #
      # Plain Ruby over Interviews' own commands, reached through the `dispatch` it is given;
      # nothing is stored here, so nothing of a client's lands in Hecks. An event is the `-> Placed`
      # half of an action statement, not a kind of its own.
      class DomainDraft
        # @param proposer [#call] takes an exchange and its number, answers `{kind:, statement:}`
        #   Points
        # @param dispatch [#call] takes a command name and its attributes, like `dispatch_flat`
        # @param reference [String] the interview's reference
        def initialize(proposer:, dispatch:, reference:)
          @proposer = proposer
          @dispatch = dispatch
          @reference = reference
          @proposed = {}
        end

        # @param exchange [Hash] exchange `number` as the interview holds it
        # @param number [Integer] the exchange's number, from one
        # @return [Array<Integer>] the numbers of the Points proposed for it
        def turn(exchange, number)
          @proposer.call(exchange, number).map { |point| propose(point, number) }
        end

        # Accepts a Point as it was proposed, so its kind and statement are not overwritten.
        #
        # @param number [Integer] a proposed Point's number
        def accept(number)
          point = @proposed.fetch(number)
          call("Interviews::Interview.Point.Accept", reference: wrap(@reference), number: wrap(number),
                                                      kind: wrap(point[:kind]), statement: wrap(point[:statement]))
        end

        # @param number [Integer] a proposed Point's number
        def reject(number)
          call("Interviews::Interview.Point.Reject", reference: wrap(@reference), number: wrap(number))
        end

        # @param subject [String] what the interview is about
        # @param interview [Hash] the interview's state as plain data
        # @return [String] the bluebook text of the accepted Points, quoting the client
        def text(subject:, interview:)
          Quoted.call(SME::DiscoveryProjection.text(subject: subject, points: points(interview)),
                      exchanges(interview))
        end

        # @return [Hash] `:text` and the staged `:verdict` of `DiscoveryProjection.check`
        def check(subject:, interview:)
          SME::DiscoveryProjection.check(subject: subject, points: points(interview))
                                  .merge(text: text(subject: subject, interview: interview))
        end

        private

        def propose(point, source)
          number = @proposed.size + 1
          @proposed[number] = point
          call("Interviews::Interview.ProposePoint", interview: @reference, number: wrap(number),
                                                      kind: wrap(point[:kind]), statement: wrap(point[:statement]),
                                                      source: wrap(source))
          number
        end

        def call(name, **attrs) = @dispatch.call(name, **attrs)

        def wrap(value) = { value: value }

        def points(interview)
          interview[:points].map do |point|
            { number: point[:number][:value], kind: point[:kind][:value], statement: point[:statement][:value],
              source: point[:source][:value], status: point[:status] }
          end
        end

        def exchanges(interview)
          interview[:exchanges].map { |e| { speaker: e[:speaker], answer: e[:answer] } }
        end
      end
    end
  end
end
