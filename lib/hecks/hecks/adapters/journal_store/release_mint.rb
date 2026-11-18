# frozen_string_literal: true

require_relative "held_mint"
require_relative "held_domain"
require_relative "../../../shape_ledger"

module Hecks
  module Adapters
    class JournalStore
      # The one mint per release, answered on the `JournalStore` port's `ReleaseMint`.
      #
      # It refuses first, by name, any bluebook whose shape moved in a way that is neither provably
      # additive nor covered by a translation edge (the decision `MintDecision` and the commit-time
      # gate share). Then it mints the domain's next era once, from the held era's stored projection
      # to the current shape, through `HeldMint`, and moves the shape ledger to the shapes released.
      # A domain on a store that holds no eras, or a disposable ledger, mints nothing and still has
      # its ledger moved. The ledger is written by this and nothing else.
      class ReleaseMint
        # @param directory [String] the domain's bluebook directory
        # @param minter [#call, nil] mints (era, request) for the domain; the era mint of the
        #   directory's own ledger when not given
        # @param reader [#call, nil] reads the facts of the directory, as `HeldMint.read` does
        def initialize(directory:, minter: nil, reader: nil)
          @directory = directory
          @minter = minter || method(:mint)
          @reader = reader
        end

        # @param run [String] the run the mint belongs to
        # @param confirm [Boolean, nil] whether the release mint was confirmed
        # @return [Hash{Symbol => Hash}] `run`, `outcome` (`minted`, `no_change`, `eraless` or
        #   `disposable`) and `label`, as `HeldMint#answer` answers
        # @raise [Runtime::WiringError] naming why the mint was refused
        def answer(run:, confirm: nil)
          raise Runtime::WiringError, "the release mint needs --confirm" unless confirm == true

          refuse_uncovered!
          answered = HeldMint.new(directory: @directory, minter: @minter, reader: @reader).answer(run: run, confirm: true)
          ShapeLedger.check(@directory, confirm: true)
          answered
        end

        private

        def refuse_uncovered!
          refusals = ShapeLedger.refusals(@directory)
          raise Runtime::WiringError, "release mint refused: #{refusals.join("; ")}" unless refusals.empty?
        end

        def mint(era, request)
          name = HeldDomain.open(@directory).domain_name
          QaRevisionMint.call(@directory, domain: name, era: era, request: request, ledger: @directory)
        end
      end
    end
  end
end
