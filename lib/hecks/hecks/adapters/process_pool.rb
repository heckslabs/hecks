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

      # Signals passed on to a running child's process group.
      FORWARDED = %w[INT TERM].freeze

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
        if plain(held[:domain]).nil? && !RustWorkspace.new.checkout?
          raise ConsoleCapture::Failure, "name a domain (hecks fuzz <domain>): sweeping every domain " \
                                         "needs a hecks checkout"
        end

        command = [RbConfig.ruby, script("fuzz")]
        command << plain(held[:domain]) if plain(held[:domain])
        { "--seeds" => :seeds, "--steps" => :steps, "--workers" => :workers, "--adapter" => :adapter }.each do |flag, key|
          command.push(flag, plain(held[key]).to_s) unless plain(held[key]).nil?
        end

        answer(run(command, env: { "HECKS_NO_3_0_NOTICE" => "1" }))
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
        options = { pgroup: true, out: output, err: output }
        options[:chdir] = chdir if chdir
        pid = spawn(env, *command, **options)
        previous = FORWARDED.to_h { |name| [name, trap(name) { forward(name, pid) }] }
        _, status = Process.wait2(pid)
        Finished.new(File.read(output.path), status)
      rescue Errno::ENOENT => e
        Finished.new(e.message, Struct.new(:success?, :exitstatus).new(false, 127))
      ensure
        previous&.each { |name, handler| trap(name, handler) }
        output&.close!
      end

      private

      def forward(name, pid)
        Process.kill(name, -pid)
      rescue Errno::ESRCH
        nil
      end

      def answer(finished)
        raise ConsoleCapture::Failure, finished.output.strip unless finished.ok?

        { report: { value: finished.output } }
      end

      def script(name) = File.expand_path("../../../../bin/#{name}", __dir__)

      def plain(argument) = argument.is_a?(Hash) ? argument[:value] : argument
    end
  end
end
