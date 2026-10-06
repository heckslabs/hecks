# frozen_string_literal: true

require_relative "root_mod/notes"

module Hecks
  module RustBuild
    class ProjectRust
      # Writes `src/generated/mod.rs`: a `pub mod` per generated directory, the feature-gated
      # `active` re-export of the selected domain, and a `compile_error!` for each pair of
      # non-default domain features enabled together.
      class RootMod
        # @param file [IO] where the module is written
        # @param directories [Array<String>] every directory under `src/generated`
        # @param domains [Array<String>] the directories that carry their own `merged.rs`
        # @param default [String] the domain this run generated, whose feature is the default
        def initialize(file, directories, domains, default)
          @file = file
          @directories = directories
          @domains = domains
          @default = default
        end

        # @return [void]
        def write
          banner
          modules
          active_notes
          reexports
          conflict_guards
        end

        private

        def banner
          @file.puts Notes::BANNER
        end

        def modules
          @directories.each do |name|
            @file.puts "#[cfg(feature = #{name.inspect})]" if @domains.include?(name)
            @file.puts "pub mod #{name};"
          end
        end

        def active_notes
          @file.puts
          @file.puts Notes.active(@default)
        end

        def reexports
          @domains.each do |name|
            other_domains = @domains - [name]
            if name == @default && !other_domains.empty?
              guard = other_domains.map { |o| "feature = #{o.inspect}" }.join(", ")
              @file.puts "#[cfg(all(feature = #{name.inspect}, not(any(#{guard}))))]"
            else
              @file.puts "#[cfg(feature = #{name.inspect})]"
            end
            @file.puts "pub use #{name}::merged as active;"
          end
        end

        def conflict_guards
          non_default_domains = @domains - [@default]
          return unless non_default_domains.size > 1

          @file.puts
          @file.puts "// Explicit conflict guard — see point 2 above. Only fires when TWO"
          @file.puts "// non-default domain features are both turned on; the default"
          @file.puts "// domain's own feature never reaches here (point 1 already excludes"
          @file.puts "// it whenever any other domain feature is present)."
          non_default_domains.combination(2).each { |first, second| conflict_guard(first, second) }
        end

        def conflict_guard(first, second)
          @file.puts "#[cfg(all(feature = #{first.inspect}, feature = #{second.inspect}))]"
          # Plain `first`/`second`/`domains.join` here, never `.inspect` — this whole
          # line already sits inside one Rust string literal
          # (`compile_error!("...")`), and `.inspect`'s own quoted form
          # would nest unescaped double quotes and produce invalid Rust.
          @file.puts "compile_error!(\"domain features are mutually exclusive — enable only one of: #{@domains.join(", ")} " \
                     "(both #{first} and #{second} are enabled)\");"
        end
      end
    end
  end
end
