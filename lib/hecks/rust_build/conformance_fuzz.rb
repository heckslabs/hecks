# frozen_string_literal: true

require "fileutils"
require "json"
require_relative "../rust_build"
require_relative "conformance"

module Hecks
  module RustBuild
    # Runs generated fuzz sequences through `Conformance` against a native or `.wasm` artifact
    # (ADR 0039), stopping at the first diverging seed with a reproduction command.
    #
    #   ConformanceFuzz.call([domain, "native" | "path/to/module.wasm", seeds, steps])
    #
    # `seeds` and `steps` default to `SEEDS` and `STEPS` in the environment, then to 10 and 25.
    module ConformanceFuzz
      USAGE = "usage: bin/rust_conformance_fuzz <domain> <native|path/to/module.wasm> [seeds] [steps]"

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
        # Under tmp/, not a temp directory, so a failing seed's script outlives the run.
        base = File.writable?(ROOT) ? ROOT : Dir.pwd
        scratch = File.join(base, "tmp", "rust_conformance_fuzz", File.basename(domain))
        FileUtils.rm_rf(scratch)
        FileUtils.mkdir_p(scratch)
        (1..seeds).each { |seed| replay(domain, artifact, seed, seeds, steps, scratch) }
        FileUtils.rm_rf(scratch)
        puts "#{domain}: #{seeds} generated sequence(s) x #{steps} step(s) each, all matched #{artifact}."
        0
      end

      def replay(domain, artifact, seed, seeds, steps, scratch)
        sequence = Hecks::Fuzzing::SequenceGenerator.generate(domain, seed: seed, steps: steps)
        path = File.join(scratch, "seed-#{seed}.json")
        File.write(path, JSON.generate({ "steps" => sequence }))
        return if Conformance.call([domain, path, artifact]).zero?

        raise Failure, "bin/rust_conformance_fuzz: seed #{seed}/#{seeds} diverged against #{artifact} " \
                       "(see the conformance output above) — " \
                       "reproduce with: bin/rust_conformance #{domain} #{path} #{artifact}"
      end
    end
  end
end
