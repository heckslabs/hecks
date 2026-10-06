# frozen_string_literal: true

require "fileutils"
require "json"
require "tmpdir"
require_relative "../cache_dir"
require_relative "../rust_build"
require_relative "conformance"
require_relative "kernel_input"

module Hecks
  module RustBuild
    # Runs generated fuzz sequences through `Conformance` against a native or `.wasm` artifact
    # (ADR 0039), stopping at the first diverging seed with a reproduction command.
    #
    #   ConformanceFuzz.call([domain, "native" | "path/to/module.wasm", seeds, steps])
    #
    # `seeds` and `steps` default to `SEEDS` and `STEPS` in the environment, then to 10 and 25.
    module ConformanceFuzz
      USAGE = "usage: hecks fuzz_conformance <domain> <native|path/to/module.wasm> [seeds] [steps]"

      # What a domain directory's basename may be: a plain identifier, never `.` or `..`.
      DOMAIN_NAME = /\A[A-Za-z0-9][A-Za-z0-9_-]*\z/

      # One fuzz run: what is replayed, against which artifact, how much, and where the scripts go.
      Run = Struct.new(:domain, :artifact, :seeds, :steps, :scratch)

      module_function

      # @param argv [Array<String>] the domain, the artifact, and optionally seeds and steps
      # @return [Integer] 0 when every sequence matched
      # @raise [Failure] at the first seed that diverges, naming how to reproduce it
      def call(argv)
        require_relative "../../hecks"
        require_relative "../fuzzing"
        run = build_run(argv)
        (1..run.seeds).each { |seed| replay(run, seed) }
        FileUtils.rm_rf(run.scratch)
        puts "#{run.domain}: #{run.seeds} generated sequence(s) x #{run.steps} step(s) each, " \
             "all matched #{run.artifact}."
        0
      end

      def build_run(argv)
        domain, artifact, seeds, steps = argv
        raise Failure, USAGE unless domain && artifact

        Run.new(domain, artifact, Integer(seeds || ENV["SEEDS"] || 10), Integer(steps || ENV["STEPS"] || 25),
                scratch_dir(domain))
      end

      # A fresh directory per run, under the cache root outside the gem, so concurrent runs never
      # share one; it is kept when a seed diverges, so the failing script outlives the run.
      #
      # @param domain [String] the domain's directory; its basename names the scratch directory
      # @return [String] the new directory
      # @raise [Failure] when the basename cannot safely name a directory
      def scratch_dir(domain)
        name = File.basename(domain.to_s.chomp("/"))
        raise Failure, "#{USAGE}\n`#{domain}` is not a domain directory name" unless name.match?(DOMAIN_NAME)

        parent = Hecks::CacheDir.path("rust_conformance_fuzz")
        FileUtils.mkdir_p(parent)
        Dir.mktmpdir("#{name}-", parent)
      end

      def replay(run, seed)
        sequence = Hecks::Fuzzing::SequenceGenerator.generate(run.domain, seed: seed, steps: run.steps)
        path = File.join(run.scratch, "seed-#{seed}.json")
        File.write(path, KernelInput.json(run.domain, sequence))
        return if Conformance.call([run.domain, path, run.artifact]).zero?

        raise Failure, divergence_message(run, seed, path)
      end

      def divergence_message(run, seed, path)
        "hecks fuzz_conformance: seed #{seed}/#{run.seeds} diverged against #{run.artifact} " \
          "(see the conformance output above) — " \
          "reproduce with: hecks check_conformance #{run.domain} #{path} #{run.artifact}"
      end
    end
  end
end
