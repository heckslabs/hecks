require_relative "ruby_runner"
require_relative "../rust_build/kernel_client"
require_relative "../rust_build/kernel_input"
require_relative "../runtime/kernel_dispatcher"

module Hecks
  module Bench
    # Times the Rust kernel the way `Hecks.boot(path, engine: :kernel)` serves it: each command goes
    # through a {Runtime::KernelDispatcher} over a {RustBuild::KernelClient}, so a timing holds
    # the JSON each way, the pipe and the Ruby work on the answer (events rebuilt as
    # `Runtime::Event` objects, the dispatcher's log filled). `RustRunner` times the raw pipe and
    # understates that.
    #
    # The run also reports how long the boot took (spawn, the `needs` table from the IR, `hello`),
    # the cost the kernel would add to the front of `exe/hecks`.
    module KernelRunner
      module_function

      # @param workload [Workload] the commands to time
      # @param binary [String] a kernel built for the workload's domain
      # @param warmup [Integer] cycles discarded before timing
      # @param iterations [Integer] timed cycles
      # @return [Run] the timings, with `:boot_us` as an extra
      def call(workload, binary:, warmup:, iterations:)
        RubyRunner.load_dependencies
        dispatcher, boot_seconds = timed { connect(workload, binary) }
        run = RubyRunner.run_workload(dispatcher, workload, warmup, iterations)
        Run.new(samples: run.samples, wall_seconds: run.wall_seconds,
                extras: { boot_us: Stats.micros(boot_seconds) })
      ensure
        dispatcher&.close
      end

      # @return [Array(Object, Float)] the block's value and the seconds it took
      def timed
        began = RubyRunner.now
        value = yield
        [value, RubyRunner.now - began]
      end

      # Connects a dispatcher; a domain with `needs` gets a clock to answer them with.
      def connect(workload, binary)
        needs = RustBuild::KernelInput.tables_for(workload.domain_path).fetch("needs")
        client = RustBuild::KernelClient.open(binary, needs: needs, &(needs.empty? ? nil : method(:answer)))
        Runtime::KernelDispatcher.new(client)
      end

      # The host's answer to a needed fact: the clock, as the attribute's type wants it.
      #
      # @return [Integer, Hash, nil] epoch seconds for an Integer, a value object around them
      #   otherwise, and nil for a fact the bench has no answer for
      def answer(fact, type, _verb)
        return unless fact == "now"

        seconds = Time.now.to_i
        type == "Integer" ? seconds : { "value" => seconds }
      end
    end
  end
end
