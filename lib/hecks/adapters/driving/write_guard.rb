# frozen_string_literal: true

require_relative "context_line"
require_relative "../driven/worktree_overlay"

module Hecks
  module Adapters
    module Driving
      # Decides what a write from a linked worktree must do when the worktree would store it in
      # Memory while the main checkout stores it elsewhere. Such a write is never silently lost:
      # it goes to the main checkout (`Verdict#forward`) or is refused by name (`Verdict#refusal`).
      # It asks the same overlay question the worktree warning asks (WorktreeOverlay.gap), and
      # reads stores the way `hecks config` does, so the decision and the warning cannot disagree
      # about what is missing.
      #
      # A store is looked up by the command's own aggregate first (`store Tickets::Work`), then by
      # its bluebook (`store Tickets`): a hecksagon binds stores per aggregate, so a bluebook that
      # reads as Memory can still hold aggregates that persist.
      module WriteGuard
        # What to do with a write: `forward` is the main checkout to run it in, `refusal` the
        # message that stops it; both nil lets it run here.
        Verdict = Struct.new(:forward, :refusal, keyword_init: true) do
          # @return [Boolean] whether the write may run in this checkout
          def allowed? = forward.nil? && refusal.nil?
        end

        # The variable that turns forwarding off, so a guarded write is refused instead.
        NO_FORWARD = "HECKS_NO_FORWARD"
        # The variable a forwarded run carries, so it can never be forwarded again.
        FORWARDED = "HECKS_FORWARDED"

        module_function

        # @param directory [String] the checkout the command runs in
        # @param bluebook [String, nil] the bluebook the command belongs to
        # @param aggregate [String, nil] the aggregate the command acts on
        # @param stores [#call] answers the store rows of a directory
        # @param env [#[]] where the forwarding switches are read
        # @return [Verdict]
        def verdict(directory, bluebook, aggregate: nil, stores: STORES, env: ENV)
          main = divergent_main(directory, bluebook, aggregate, stores)
          return Verdict.new unless main

          text = message(bluebook, aggregate, main)
          return Verdict.new(refusal: text) if !env[FORWARDED].to_s.empty? || !env[NO_FORWARD].to_s.empty?

          Verdict.new(forward: main[:root])
        end

        # @param directory [String] the checkout the command runs in
        # @param bluebook [String, nil] the bluebook the command belongs to
        # @param aggregate [String, nil] the aggregate the command acts on
        # @param stores [#call] answers the store rows of a directory
        # @return [String, nil] the refusal, or nil when the write may proceed or be forwarded
        def refusal(directory, bluebook, aggregate: nil, stores: STORES, env: {})
          verdict(directory, bluebook, aggregate: aggregate, stores: stores, env: env.merge(NO_FORWARD => "1")).refusal
        end

        # The main checkout and what it stores, when this worktree would lose the write.
        #
        # @return [Hash{Symbol => Object}, nil] `root:`, `kind:` and `files:`, or nil when nothing
        #   is lost
        def divergent_main(directory, bluebook, aggregate, stores)
          return unless bluebook

          main, files = WorktreeOverlay.gap(directory)
          return if files.empty?

          kind = kind_in(stores.call(main), bluebook, aggregate)
          here = kind_in(stores.call(WorktreeOverlay.checkout_root(directory)), bluebook, aggregate)
          return if kind == ContextLine::MEMORY || kind == here

          { root: main, kind: kind, files: files }
        end

        # @param rows [Array<Array(String, String, String)>] store rows
        # @param bluebook [String]
        # @param aggregate [String, nil] the aggregate whose own binding is looked up first
        # @return [String] the kind of store used, Memory when none is declared
        def kind_in(rows, bluebook, aggregate = nil)
          labels = [aggregate && "store #{bluebook}::#{aggregate}", "store #{bluebook}"].compact
          row = labels.filter_map { |label| rows.find { |found, _value, _source| found == label } }.first
          ContextLine.kind(row ? row[1] : ContextLine::MEMORY)
        end

        # @return [String] the refusal naming the store, the missing files and the main checkout
        def message(bluebook, aggregate, main)
          "hecks: refused: #{[bluebook, aggregate].compact.join("::")} stores in #{main[:kind]} in the main " \
            "checkout, and this worktree lacks #{main[:files].join(", ")}, so the write would land in " \
            "Memory here. Run the command from the main checkout (#{main[:root]})."
        end

        # Answers the store rows of a checkout root, through the adapter `hecks config` uses, which
        # reads a domain directory. This boots a second copy of the domain; the runner passes rows
        # it already holds instead (see LedgerStores).
        STORES = lambda do |root|
          require_relative "../../hecks/adapters/settings_reading"
          Hecks::Adapters::SettingsReading.new.stores(File.join(root, "lib/hecks/hecks"))
        end
      end
    end
  end
end
