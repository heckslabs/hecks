require_relative "../../runtime/registry"

module Hecks
  module Behaviors
    module Expectations
      # Which `.adapter` files a behaviors suite boots, chosen without a list (ADR 0171): every
      # project adapter that says `stays_inside`, every stand-in in `behavior_adapters/` beside
      # the suite, and any adapter the suite names in `loads`. A stand-in or a named adapter takes
      # its port from the project's. A project adapter that reaches outside is never loaded, and
      # its Ruby never runs: its declaration is read with its `require` lines left out.
      #
      # A project opts in by having a `behavior_adapters/` directory beside the suite or by any of
      # its adapters saying `stays_inside`; until then its suites keep the loader's own choice.
      #
      # **Variants.** Two stand-ins beside a suite for the same port are rivals, not a conflict:
      # the suite is the port's contract, and `variants` boots it once per rival, so each adapter
      # is held to the same tests.
      module AdapterSelection
        STAND_INS = "behavior_adapters".freeze
        PROJECT_PATTERNS = %w[*.adapter */*.adapter */*/*.adapter].freeze
        REQUIRE_LINE = /\A\s*require(?:_relative)?\s+["'][^"']+["']\s*\z/
        SELECTIONS = {} # rubocop:disable Style/MutableConstant -- a per-process cache, filled under the lock
        SELECTIONS_LOCK = Mutex.new
        private_constant :SELECTIONS, :SELECTIONS_LOCK

        module_function

        # @param suite_path [String] the `.behaviors` file
        # @param files [Array<String>] the suite's `loads`, absolute
        # @param picked [Array<String>, nil] one stand-in per rivalled port, as `variants` picks
        #   them; nil boots the suite as if it had no rivals
        # @return [Array<String>, nil] the `.adapter` files to boot, absolute, in a stable
        #   order; nil when the suite's project has not opted in
        def call(suite_path, files, picked = nil)
          key = [suite_path, files, picked]
          SELECTIONS_LOCK.synchronize do
            SELECTIONS.fetch(key) { SELECTIONS[key] = choose(suite_path, files, picked) }
          end
        end

        # Every way the suite boots: once per pick of one stand-in for each port that has
        # rivals beside the suite, or once when none has.
        #
        # @param suite_path [String] the `.behaviors` file
        # @param files [Array<String>] the suite's `loads`, absolute
        # @return [Array<Array(String, Array<String>)>] each variant's label, naming the adapters
        #   it picked, and its `.adapter` files; a single variant labelled nil when there are no
        #   rivals
        def variants(suite_path, files)
          contested = rivals(suite_path).values
          return [[nil, call(suite_path, files)]] if contested.empty?

          contested.first.product(*contested.drop(1)).map { |picked| [label(picked), call(suite_path, files, picked)] }
        end

        # @return [Hash{String => Array<String>}] the stand-ins beside the suite, by port, for each
        #   port that more than one of them answers
        def rivals(suite_path)
          by_port = stand_ins(suite_path).group_by { |file| ports_of(file) }
          by_port.select { |ports, rows| ports.size == 1 && rows.size > 1 }
        end

        # @return [String] the names of the adapters a variant picked
        def label(picked) = picked.flat_map { |file| declarations(file).map(&:name) }.join(" and ")

        def choose(suite_path, files, picked)
          project = project_adapters(files)
          return nil unless opted_in?(suite_path, project)

          chosen = files.select { |file| file.end_with?(".adapter") } + picked_stand_ins(suite_path, picked)
          claimed = chosen.flat_map { |file| ports_of(file) }
          (chosen + project.select { |file| inside_and_unclaimed?(file, claimed) }).uniq.sort
        end

        # @return [Array<String>] the stand-ins a variant boots: all but the rivals it did not pick
        def picked_stand_ins(suite_path, picked)
          return stand_ins(suite_path) unless picked

          stand_ins(suite_path) - (rivals(suite_path).values.flatten - picked)
        end

        def opted_in?(suite_path, project)
          stand_ins(suite_path).any? || project.any? { |file| declarations(file).any?(&:stays_inside?) }
        end

        # @return [Array<String>] the stand-ins beside the suite
        def stand_ins(suite_path) = Dir.glob(File.join(File.dirname(suite_path), STAND_INS, "*.adapter"))

        # @return [Array<String>] the project's own adapters, found as the loader finds them
        def project_adapters(files)
          root = Ports::Loading.bootstrap.shared_root(nil, File.dirname(files.first))
          return [] unless root

          PROJECT_PATTERNS.flat_map { |pattern| Dir.glob(File.join(root, "adapters", pattern)) }.sort
        end

        def inside_and_unclaimed?(file, claimed)
          declared = declarations(file)
          declared.any? && declared.all?(&:stays_inside?) && !declared.map(&:port).intersect?(claimed)
        end

        def ports_of(file) = declarations(file).map(&:port)

        # The adapters a file declares, read in a throwaway registry with its `require` lines left
        # out, so an adapter that reaches outside is never constructed and its code never loads.
        #
        # @param file [String] an `.adapter` file
        # @return [Array<Bluebook::Adapter>] none when the file cannot be read on its own
        def declarations(file)
          text = File.readlines(file).grep_v(REQUIRE_LINE).join
          registry = Runtime::Registry.new
          Hecks.with_registry(registry) { TOPLEVEL_BINDING.eval(text, file) }
          registry.adapters.values
        rescue StandardError, ScriptError
          # A declaration that cannot be read without its code is treated as reaching outside.
          []
        end
      end
    end
  end
end
