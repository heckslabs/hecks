# Hecks::Parity::Fuzz::Runner::RubyDispatcher
#
# Purpose: run a fuzzer Program through the Ruby BehaviorRuntime
# in-process, then persist the final in-memory repositories to
# .heki files in the same binary envelope the Rust runtime uses.
# This is the Ruby-side analogue of `hecks-life aggregates/
# Agg.Cmd` — but all commands share one BehaviorRuntime, so state
# carries across the program the same way Rust's per-invocation
# persist/re-load does.
#
# [antibody-exempt: differential fuzzer per i30 plan — retires when
# fuzzer ports to bluebook-dispatched form via hecks-life run]

require "hecks"
require "hecks/behaviors/behavior_runtime"
require "hecks/behaviors/value"
require_relative "heki_writer"

module Hecks
  module Parity
    module Fuzz
      module Runner
        module RubyDispatcher
          module_function

          def run(program, ruby_root, ruby_info)
            bluebook_path = File.join(ruby_root, "aggregates", "#{program.name}.bluebook")
            domain = load_domain(bluebook_path)
            return "ruby load failed: no domain" unless domain
            rt = Hecks::Behaviors::BehaviorRuntime.boot(domain)
            errors = []
            program.commands.each_with_index do |step, i|
              begin
                dispatch_one(rt, step)
              rescue => e
                errors << "step #{i} #{step[:aggregate]}.#{step[:command]}: #{e.class}"
              end
            end
            HekiWriter.write_all(rt, ruby_info)
            errors.empty? ? nil : errors.join("; ")
          rescue => e
            "ruby dispatcher crashed: #{e.class}: #{e.message}"
          end

          def load_domain(path)
            # Same VoTypeResolution wrapping as parity_test.rb's ruby_dump.
            Hecks.instance_variable_set(:@last_domain, nil)
            Hecks::DSL::AggregateBuilder::VoTypeResolution.with_vo_constants do
              Kernel.load(path)
            end
            Hecks.last_domain
          end

          def dispatch_one(rt, step)
            attrs = (step[:attrs] || {}).transform_values do |v|
              Hecks::Behaviors::Value.from(v)
            end
            rt.dispatch(step[:command], attrs.transform_keys(&:to_s))
          end
        end
      end
    end
  end
end
