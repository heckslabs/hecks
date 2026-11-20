require "hecks"
require "hecks/tools/tools_doc"
require "hecks/command_names"

module Hecks
  module Doc
    module CliGuides
      # The command line as ADR 0163 lays it out: the Hecks bluebook's modules, each with its vision
      # and the aggregates it groups, and the commands and queries of each aggregate as the
      # launcher projects them. Booted once from a checkout.
      #
      # @example
      #   Layout.new(root).verbs("Deliver").first # => { group: "Workspace", lines: [...] }
      class Layout
        # The first sentence of a description: up to its first full stop, `!` or `?`.
        FIRST_SENTENCE = /\A.*?[.!?](?=\s|\z)/m

        # @param root [String] the checkout
        def initialize(root)
          @runtime = Hecks.boot(File.join(root, "lib/hecks/hecks"), install_driving: false)
          @bluebook = @runtime.bluebook("Hecks")
        end

        # @return [Array<Array(String, String)>] each module's name and vision, in declaration order
        def modules
          @bluebook.modules.uniq(&:name).map { |row| [row.name, row.vision.to_s] }
        end

        # The commands and queries a person is listed for in one module, by aggregate.
        #
        # @param name [String] a module's name, such as `Deliver`
        # @return [Array<Hash>] `{ group:, description:, verbs: [{ call:, form:, summary: }] }` per
        #   aggregate that lists something, in the module's order
        def verbs(name)
          members(name).filter_map do |group|
            listed = specs.select { |spec| spec[:group] == group && !spec[:internal] }
            next if listed.empty?

            { group: group, description: description(group), verbs: listed.map { |spec| verb(spec) } }
          end
        end

        # @return [Set<String>] every call the launcher reaches in any bluebook the Hecks domain
        #   boots, internal ones too, such as `Landing.land!` and `Workspace.status`
        def calls
          @calls ||= bluebooks.flat_map { |name, _| all_specs(name) }.to_set { |spec| call(spec) }
        end

        # @return [Set<String>] every aggregate of every bluebook the Hecks domain boots
        def aggregates
          @aggregates ||= bluebooks.flat_map { |_, bluebook| bluebook.aggregates.map(&:hecks_name) }.to_set
        end

        private

        # @return [Array<String>] the aggregates a module groups, in declaration order
        def members(name) = @bluebook.modules.select { |row| row.name == name }.map(&:aggregate)

        # @return [Hash] one listed verb: its call, the words after `hecks`, whether the launcher
        #   accepts the call, and its goal
        def verb(spec)
          words = [launched(spec), *Tools::ToolsDoc.argument_words(spec)].join(" ")
          { call: call(spec), words: words, reached: reached?(launched(spec)), summary: spec[:summary].to_s }
        end

        # @return [String] the call as a bluebook spells it: `Aggregate.verb`, a command's banged
        def call(spec)
          "#{spec[:group]}.#{spec[:short].to_s.split(".").last}#{bang(spec)}"
        end

        # @return [String] the call as the launcher takes it: its routed word when it has one
        def launched(spec)
          route = routes.key(spec[:key]) || routes.key(spec[:short].to_s)
          route ? "#{route}#{bang(spec)}" : call(spec)
        end

        def bang(spec) = ("!" if spec[:kind] == :command)

        # @return [Hash{String => String}] each word the launcher routes to a Hecks command or query
        def routes = (Adapters::Driving::LauncherOptions.settings(@runtime, "Hecks") || {})[:names] || {}

        # @return [Boolean] whether the launcher accepts the call as typed
        def reached?(typed)
          @names ||= CommandNames::Index.new(Adapters::Driving::CliRunner.name_index(runtime: @runtime))
          @names.problem([typed]).nil?
        end

        # @return [String] the first sentence of the aggregate's description, or `""`
        def description(group)
          text = aggregate_named(group)&.description.to_s
          text[FIRST_SENTENCE] || text
        end

        # @return [Bluebook::Aggregate, nil] the Hecks bluebook's aggregate of that name
        def aggregate_named(group) = @bluebook.aggregates.find { |aggregate| aggregate.hecks_name == group }

        # @return [Array<Hash>] every projected command, then every query, of the Hecks bluebook
        def specs = @specs ||= all_specs("Hecks")

        # @return [Hash{String => Bluebook::Declaration}] every bluebook the boot holds
        def bluebooks = @runtime.bluebooks

        # @param name [String] a bluebook the boot holds
        # @return [Array<Hash>] its projected commands, then its queries, each with its `key`
        def all_specs(name)
          cli = projection(name)
          cli[:commands].merge(cli[:questions]).map { |key, spec| spec.merge(key: key) }
        end

        # @return [Hash] the launcher's projection of one bluebook
        def projection(name)
          launcher = Adapters::Driving::LauncherOptions.settings(@runtime, name)
          options = Adapters::Driving::LauncherOptions.projection(launcher, "hecks")
          Projector.call(:cli, bluebook: @runtime.bluebook(name), options: options)
        end
      end
    end
  end
end
