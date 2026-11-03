# Generated - projected from the CacheInput rows of the Syntax aggregate in
# lib/hecks/language/bluebook/syntax.bluebook.
#
# Do not edit. Run `hecks project_parser_table`; the codegen drift job diffs this file.
#
# Plain data, no requires: the verdict cache and the syntax table cache read it before the
# grammar registry is built. A file enters a digest when a `digest: true` glob matches it and
# no `digest: false` glob does. Globs are relative to lib/.

module Hecks
  module Bluebook
    module MetaValidator
      # The path classes a cache digest reads, declared once in the grammar.
      module CacheInput
        # Every member: its name, whether it enters the digest, and the glob it reads.
        MEMBERS = [
          { name: "Lib", digest: true, glob: "**/*" },
          { name: "Grammar", digest: true, glob: "hecks/language/**/*" },
          { name: "PreamblePorts", digest: true, glob: "hecks/ports/{persistence,extraction}.port" },
          { name: "PreambleAdapters", digest: true, glob: "hecks/adapters/driven/{memory,prism}.adapter" },
          { name: "Projections", digest: true, glob: "hecks/projections{/**/*,.rb}" },
          { name: "Bench", digest: false, glob: "hecks/bench{/**/*,.rb}" },
          { name: "Cli", digest: false, glob: "hecks/cli{/**/*,.rb}" },
          { name: "Codemod", digest: false, glob: "hecks/codemod{/**/*,.rb}" },
          { name: "Deploy", digest: false, glob: "hecks/deploy{/**/*,.rb}" },
          { name: "Doc", digest: false, glob: "hecks/doc{/**/*,.rb}" },
          { name: "DrivingAdapters", digest: false, glob: "hecks/adapters/driving{/**/*,.rb}" },
          { name: "Fuzzing", digest: false, glob: "hecks/fuzzing{/**/*,.rb}" },
          { name: "QualityControl", digest: false, glob: "hecks/quality_control{/**/*,.rb}" },
          { name: "Release", digest: false, glob: "hecks/release{/**/*,.rb}" }
        ].freeze
      end
    end
  end
end
