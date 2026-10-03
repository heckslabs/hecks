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

      module_function

      # @param argv [Array<String>] the domain, the artifact, and optionally seeds and steps
      # @return [Integer] 0 when every sequence matched
      # @raise [Failure] at the first seed that diverges, naming how to reproduce it
      def call(argv)
        require_relative "../../hecks"
        require_relative "../fuzzing"
        domain, artifact, seeds, steps = argv
        raise Failure, USAGE unless domain && artifact

        seeds = Integer(seeds || ENV["SEEDS"] || 10)
        steps = Integer(steps || ENV["STEPS"] || 25)
        scratch = scratch_dir(domain)
        (1..seeds).each { |seed| replay(domain, artifact, seed, seeds, steps, scratch) }
        FileUtils.rm_rf(scratch)
        puts "#{domain}: #{seeds} generated sequence(s) x #{steps} step(s) each, all matched #{artifact}."
        0
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

      def replay(domain, artifact, seed, seeds, steps, scratch)
        sequence = Hecks::Fuzzing::SequenceGenerator.generate(domain, seed: seed, steps: steps)
        path = File.join(scratch, "seed-#{seed}.json")
        File.write(path, KernelInput.json(domain, sequence))
        return if Conformance.call([domain, path, artifact]).zero?

        raise Failure, "hecks fuzz_conformance: seed #{seed}/#{seeds} diverged against #{artifact} " \
                       "(see the conformance output above) — " \
                       "reproduce with: hecks check_conformance #{domain} #{path} #{artifact}"
      end
    end
  end
end
