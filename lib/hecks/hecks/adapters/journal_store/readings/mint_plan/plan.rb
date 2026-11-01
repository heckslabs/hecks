# frozen_string_literal: true

require_relative "../../held_domain"
require_relative "report"
require_relative "world"
require_relative "inspection"

module Hecks
  module Adapters
    class JournalStore
      module Readings
        module MintPlan
          # The preflight of a mint: every guard the mint runs, against the store it would mint in,
          # read-only. It decides nothing of its own; each guard calls the function the mint calls.
          class Plan
            AFTER_WORLD = %w[eras held_shape edge coverage audit watermark].freeze

            # @param directory [String] the domain directory
            # @param options [Hash] `bluebook`, `rehearsal_ref`, `rehearsal_watermark`,
            #   `rehearsal_verdict`, `dev_dir`
            def initialize(directory, **options)
              @directory = directory
              @options = options
              @report = Report.new
            end

            # @return [Hash] `plan`, `guards`, `command` and `seconds`
            def to_h
              loaded = @report.check("load") { load_domain } == "pass"
              held = @held if loaded
              command = held && gather(held)
              { domain: held&.domain_name, directory: @directory, plan: @report.plan,
                guards: @report.guards, command: command, seconds: @report.seconds }
            end

            private

            def load_domain
              @held = HeldDomain.open(@directory, mode: :translated)
              name = @options[:bluebook]
              @held = HeldDomain.new(@held.registry, @held.directory, name) unless name.to_s.empty?
              [:pass, "#{@held.domain_name} loaded from #{@held.directory}, no domain booted"]
            end

            def gather(held)
              world = World.new(held, dev_dir: @options[:dev_dir])
              @report.add("world", :info, world.flags)
              @report.check("stranded") { world.stranded }
              @report.add("quiesce", *world.quiesce)
              return settle("disposable", "disposable: no mint needed") if world.disposable?
              return settle("no_change", "#{held.adapter_name} holds no eras: no mint") unless held.capable?

              Inspection.new(@report, held, @options).call
            end

            def settle(plan, why)
              @report.settle(plan)
              @report.skip(AFTER_WORLD, why)
              nil
            end
          end
        end
      end
    end
  end
end
