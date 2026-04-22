# Hecks::Parity::Fuzz::Runner
#
# Purpose: dispatch a Program (generator.rb output) against both
# the Ruby and Rust runtimes in isolated temp directories, then
# return the paths to the two `.heki` trees for the comparator.
#
# Isolation strategy:
#   /tmp/fuzz-<seed>/ruby/aggregates/<name>.bluebook
#   /tmp/fuzz-<seed>/ruby/<agg>.world          (heki dir → information)
#   /tmp/fuzz-<seed>/ruby/information/*.heki   (post-run)
#   /tmp/fuzz-<seed>/rust/aggregates/<name>.bluebook
#   /tmp/fuzz-<seed>/rust/<agg>.world
#   /tmp/fuzz-<seed>/rust/information/*.heki
#
# Ruby dispatch is direct-in-process via Hecks::Behaviors::
# BehaviorRuntime — identical code path the behaviors_parity_test
# exercises. Final state is written to .heki using the same
# binary envelope (HEKI magic + zlib JSON) as the Rust runtime
# so the comparator reads them through one path.
#
# Rust dispatch is one `hecks-life aggregates/ Agg.Command k=v`
# shell invocation per command — each invocation loads/persists
# the heki tree, so the cascade crosses dispatch boundaries
# exactly the way production Miette does. Slow per-command (~100ms
# process startup) but accurate.
#
# Usage:
#   result = Runner.run(program, hecks_life_bin: HECKS_LIFE)
#   result.ruby_dir    # path to ruby-side information/
#   result.rust_dir    # path to rust-side information/
#   result.ruby_error  # nil or String (ruby dispatch crashed)
#   result.rust_error  # nil or String (rust dispatch crashed)
#
# [antibody-exempt: differential fuzzer per i30 plan — retires when
# fuzzer ports to bluebook-dispatched form via hecks-life run]

require "fileutils"
require "open3"
require "hecks"
require "hecks/behaviors/behavior_runtime"
require "hecks/behaviors/value"
require_relative "runner/heki_writer"
require_relative "runner/ruby_dispatcher"

module Hecks
  module Parity
    module Fuzz
      module Runner
        Result = Struct.new(:ruby_dir, :rust_dir, :ruby_error, :rust_error, :root, keyword_init: true)

        module_function

        def run(program, hecks_life_bin:, root: nil)
          root ||= File.join(Dir.tmpdir, "fuzz-#{program.seed}-#{Process.pid}")
          FileUtils.rm_rf(root)
          ruby_root = File.join(root, "ruby")
          rust_root = File.join(root, "rust")
          ruby_info = setup_tree(ruby_root, program)
          rust_info = setup_tree(rust_root, program)
          ruby_error = RubyDispatcher.run(program, ruby_root, ruby_info)
          rust_error = run_rust(program, rust_root, hecks_life_bin)
          Result.new(ruby_dir: ruby_info, rust_dir: rust_info, root: root,
                     ruby_error: ruby_error, rust_error: rust_error)
        end

        def setup_tree(base, program)
          agg_dir = File.join(base, "aggregates")
          info_dir = File.join(base, "information")
          FileUtils.mkdir_p(agg_dir)
          FileUtils.mkdir_p(info_dir)
          File.write(File.join(agg_dir, "#{program.name}.bluebook"), program.bluebook)
          File.write(File.join(base, "fuzz.world"), <<~WORLD)
            Hecks.world "Fuzz" do
              heki do
                dir "information"
              end
            end
          WORLD
          info_dir
        end

        def run_rust(program, rust_root, hecks_life_bin)
          agg_dir = File.join(rust_root, "aggregates") + "/"
          errors = []
          program.commands.each_with_index do |step, i|
            command_arg = "#{step[:aggregate]}.#{step[:command]}"
            kv = step[:attrs].map { |k, v| "#{k}=#{rust_value_repr(v)}" }
            stdout, status = Open3.capture2e(hecks_life_bin, agg_dir, command_arg, *kv)
            unless status.success?
              errors << "step #{i} #{command_arg}: exit=#{status.exitstatus}"
            end
          end
          errors.empty? ? nil : errors.join("; ")
        rescue => e
          "rust runner crashed: #{e.class}: #{e.message}"
        end

        # The CLI accepts `key=value` pairs — everything gets read as
        # String by dispatch_hecksagon. For fuzzer legality we only
        # generate Int/Str/Bool/list attrs; arrays go through as
        # JSON-ish "[1, 2]" and arrive at the runtime as strings
        # (which the runtime's Value coercion handles).
        def rust_value_repr(v)
          case v
          when Array then "[#{v.join(',')}]"
          when true, false then v.to_s
          else v.to_s
          end
        end
      end
    end
  end
end
