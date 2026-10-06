# frozen_string_literal: true

require "rbconfig"
require "tempfile"
require_relative "console_capture"
require_relative "rust_workspace"

module Hecks
  module Adapters
    # The `ProcessPool` port's adapter: starts a long-running child (a fuzz sweep forks its own
    # workers) and stays with it until it ends.
    #
    # The child runs in its own process group, and an interrupt or termination sent to this
    # process is passed on to the whole group, so stopping a launcher stops the workers it
    # started instead of leaving them running. Output goes to a temporary file, not a pipe, so a
    # child that writes a lot never blocks on a reader that is waiting for it to exit.
    class ProcessPool
      # What a child said and how it ended.
      #
      # @!attribute [r] output
      #   @return [String] what it wrote to stdout and stderr, in order
      # @!attribute [r] status
      #   @return [Process::Status] how it ended
      Finished = Struct.new(:output, :status) do
        # @return [Boolean] whether the child ended with status 0
        def ok? = status.success?
      end

      # The library the sweep child loads `Hecks::Tools` from.
      LIB = File.expand_path("../../..", __dir__)

      # What the sweep child runs: the `fuzz` tool, which takes the flags that follow.
      ENTRY = 'require "hecks/tools"; Hecks::Tools.script("fuzz", ARGV)'

      # What the mutation child runs: the `mutate` tool, which takes the flags that follow.
      MUTATE_ENTRY = 'require "hecks/tools"; Hecks::Tools.script("mutate", ARGV)'

      # The flags of a mutation run, and the fields of the record that fill them.
      MUTATE_FLAGS = { "--seeds" => :seeds, "--steps" => :steps, "--budget" => :budget }.freeze

      # Signals passed on to a running child's process group.
      FORWARDED = %w[INT TERM HUP QUIT].freeze

      # The flags of a sweep, and the fields of the record that fill them.
      SWEEP_FLAGS = { "--seeds" => :seeds, "--steps" => :steps, "--workers" => :workers,
                      "--adapter" => :adapter }.freeze

      class << self
        # @return [#call, nil] runs a child given `(command, env, chdir)` and answers a `Finished`;
        #   a spec replaces it so nothing is started
        attr_accessor :starter
      end

      # Accepts the arguments every driven adapter is built with and keeps none of them.
      #
      # @param aggregate [Object, nil] unused
      # @param settings [Hash] unused
      # @param root [String, nil] unused
      def initialize(aggregate: nil, settings: {}, root: nil); end

      # Runs a fuzz sweep over one domain, or over every domain of the checkout when none is named.
      #
      # @param held [Hash] the `Fuzzing` record: `domain`, `seeds`, `steps`, `workers`, `adapter`
      # @return [Hash{Symbol => Hash}] `report:` what the sweep printed
      # @raise [ConsoleCapture::Failure] when the sweep found something, or could not run
      def sweep(**held)
        refuse_unnamed_sweep(held)

        answer(run([RbConfig.ruby, "-I", LIB, "-e", ENTRY, "--", *sweep_words(held)]))
      end

      # Mutation-tests one domain: changes its rules in small ways and reports each change its
      # checks let through.
      #
      # @param held [Hash] the `Mutating` record: `domain`, `seeds`, `steps`, `budget`
      # @return [Hash{Symbol => Hash}] `report:` what the run printed
      # @raise [ConsoleCapture::Failure] when the run could not start
      def probe(**held)
        words = [plain(held[:domain])]
        MUTATE_FLAGS.each { |flag, key| words.push(flag, plain(held[key]).to_s) unless plain(held[key]).nil? }

        answer(run([RbConfig.ruby, "-I", LIB, "-e", MUTATE_ENTRY, "--", *words]))
      end

      # Starts a child, forwards interrupts to it, and waits for it to end.
      #
      # @param command [Array<String>] the program, then its arguments
      # @param env [Hash{String => String}] variables to set for it
      # @param chdir [String, nil] the directory to run it in
      # @return [Finished] what it said and how it ended
      def run(command, env: {}, chdir: nil)
        starter = self.class.starter
        return starter.call(command, env, chdir) if starter

        output = Tempfile.new("process-pool")
        status = start_and_wait(command, env, spawn_options(output, chdir))
        Finished.new(File.read(output.path), status)
      rescue Errno::ENOENT => e
        Finished.new(e.message, Struct.new(:success?, :exitstatus).new(false, 127))
      ensure
        output&.close!
      end

      private

      # The refusal for a sweep of every domain outside a checkout.
      def refuse_unnamed_sweep(held)
        return unless plain(held[:domain]).nil? && !RustWorkspace.new.checkout?

        raise ConsoleCapture::Failure, "name a domain (hecks fuzz <domain>): sweeping every domain " \
                                       "needs a hecks checkout"
      end

      # The words after `--`: the domain when named, then each flag the record names.
      def sweep_words(held)
        words = []
        words << plain(held[:domain]) if plain(held[:domain])
        SWEEP_FLAGS.each { |flag, key| words.push(flag, plain(held[key]).to_s) unless plain(held[key]).nil? }
        words << "--persist-regressions" if plain(held[:persist_regressions]) == true
        words
      end

      # The options a child is spawned with: its own process group, its output in `output`.
      def spawn_options(output, chdir)
        options = { pgroup: true, out: output, err: output }
        options[:chdir] = chdir if chdir
        options
      end

      # Starts the child and waits for it, passing on the signals sent to this process meanwhile.
      # Traps go in before the spawn, so a signal that lands while the child is starting is held
      # and passed on the moment its pid is known, instead of orphaning it.
      #
      # @return [Process::Status] how the child ended
      def start_and_wait(command, env, options)
        pid = nil
        held = []
        previous = trap_forwarded(held) { pid }
        pid = spawn(env, *command, **options)
        held.each { |name| forward(name, pid) }
        Process.wait2(pid).last
      ensure
        previous&.each { |name, handler| trap(name, handler) }
      end

      # Traps every forwarded signal, answering the handlers it replaced.
      #
      # @param held [Array<String>] collects the signals that arrive before the pid is known
      # @yield answers the child's pid, or nil while it is still starting
      def trap_forwarded(held, &)
        FORWARDED.to_h do |name|
          [name, trap(name) { (pid = yield) ? forward(name, pid) : held << name }]
        end
      end

      def forward(name, pid)
        Process.kill(name, -pid)
      rescue Errno::ESRCH
        nil
      end

      def answer(finished)
        raise ConsoleCapture::Failure, finished.output.strip unless finished.ok?

        { report: { value: finished.output } }
      end

      def plain(argument) = argument.is_a?(Hash) ? argument[:value] : argument
    end
  end
end
