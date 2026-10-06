# frozen_string_literal: true

require "fileutils"
require "json"
require "hecks/vocabulary"
require_relative "../tools"
require_relative "../hecks/adapters/github_rulesets"

module Hecks
  module Tools
    # Projects the `Lane` rows of the Vocabulary chapter into what GitHub is told about them: a
    # ruleset for each guarded lane (`.github/rulesets/<lane>.json`) and the workflow that promotes
    # each lane that follows another (`.github/workflows/promote.yml`). The workflow only runs
    # `hecks promotion_run.promote`; the rule that decides a promotion is `PromotionRun.Accept`.
    #
    # Without a flag the files are written. `--check` writes nothing and answers 1 for each file
    # that differs, which is the drift gate. `--live` compares the rulesets GitHub holds with the
    # projection and writes no file; with `--confirm` as well it creates or updates them, the one
    # step that changes GitHub.
    module Lanes
      # Where the projected rulesets and workflows live, relative to the checkout.
      RULESETS = ".github/rulesets"
      WORKFLOW = ".github/workflows/promote.yml"

      # The GitHub Actions app, which pushes with a workflow's `GITHUB_TOKEN`: the one actor a
      # `promotion` lane lets past its ruleset.
      PROMOTION_APP_ID = 15_368

      # What `pushers` may say: a lane anyone may push, or one only the promotion app may.
      PUSHERS = %w[anyone promotion].freeze

      module_function

      # @param argv [Array<String>] `--check`, `--live`, `--confirm`
      # @param root [String] the checkout
      # @return [Integer] 0, or 1 when `--check` or `--live` finds a difference
      # @raise [SystemExit] when a row is one the projection cannot express
      def main(argv, root: Tools::ROOT, rulesets: nil)
        return live(argv.include?("--confirm"), rulesets || Hecks::Adapters::GithubRulesets.new) if argv.include?("--live")

        files = projection(root)
        stale = files.reject { |path, text| File.exist?(path) && File.read(path) == text }.keys
        extra = leftover(root, files)
        return report(stale + extra, files, root) if argv.include?("--check")

        stale.each { |path| write(path, files.fetch(path)) }
        extra.each { |path| File.delete(path) }
        (stale + extra).each { |path| puts "wrote #{path.delete_prefix("#{root}/")}" }
        puts "lanes: #{lanes.size} lanes, every file current" if (stale + extra).empty?
        0
      end

      # @param root [String] the checkout
      # @return [Hash{String => String}] each file's absolute path to the text it should hold
      def projection(root)
        files = lanes.select { |lane| lane["guarded"] == "yes" }.to_h do |lane|
          [File.join(root, RULESETS, "#{lane['name']}.json"), "#{JSON.pretty_generate(ruleset(lane))}\n"]
        end
        promoted = lanes.reject { |lane| lane["follows"].to_s.empty? }
        files[File.join(root, WORKFLOW)] = workflow(promoted) unless promoted.empty?
        files
      end

      # @return [Array<Hash{String => String}>] the `Lane` rows
      # @raise [SystemExit] when a row names a pusher or a lane the projection cannot express
      def lanes
        rows = Hecks::Vocabulary.rows("Lane")
        names = rows.map { |lane| lane["name"] }
        rows.each do |lane|
          abort "lanes: #{lane['name']} has pushers #{lane['pushers'].inspect}" unless PUSHERS.include?(lane["pushers"])
          abort "lanes: #{lane['name']} has guarded #{lane['guarded'].inspect}" unless %w[yes no].include?(lane["guarded"])
          next if lane["follows"].to_s.empty? || names.include?(lane["follows"])

          abort "lanes: #{lane['name']} follows #{lane['follows'].inspect}, which is not a Lane row"
        end
      end

      # @param lane [Hash{String => String}] a guarded `Lane` row
      # @return [Hash] the ruleset GitHub is given for it
      def ruleset(lane)
        { "name" => "lane-#{lane['name']}", "target" => "branch", "enforcement" => "active",
          "conditions" => { "ref_name" => { "include" => ["refs/heads/#{lane['name']}"], "exclude" => [] } },
          "bypass_actors" => bypass(lane),
          "rules" => [{ "type" => "deletion" }, { "type" => "non_fast_forward" }, { "type" => "update" }] }
      end

      # @param lane [Hash{String => String}] a `Lane` row
      # @return [Array<Hash>] who may push past the ruleset: the promotion app, or nobody
      def bypass(lane)
        return [] unless lane["pushers"] == "promotion"

        [{ "actor_id" => PROMOTION_APP_ID, "actor_type" => "Integration", "bypass_mode" => "always" }]
      end

      # @param promoted [Array<Hash{String => String}>] the lanes that follow another
      # @return [String] the workflow: it runs after CI on the lane a lane follows, and promotes
      def workflow(promoted)
        sources = promoted.map { |lane| lane["follows"] }.uniq
        [header, *trigger(sources), *promoted.flat_map { |lane| job(lane) }].join("\n") << "\n"
      end

      def header
        <<~YAML.chomp
          name: Promote

          # Generated by hecks project_lanes from the Lane rows of the Vocabulary chapter. Do not hand-edit.
          #
          # After CI finishes on a commit of the lane a lane follows, asks `PromotionRun` to move
          # the lane onto it. Whether the commit may go is decided there (every RequiredCheck green,
          # a fast-forward of the lane), not here; a commit that is not ready yet is refused, and
          # the next push's run tries again.
        YAML
      end

      def trigger(sources)
        ["on:", "  workflow_run:", "    workflows: [CI]", "    types: [completed]",
         "    branches: [#{sources.join(', ')}]", "",
         "# One promotion at a time, in the order the pushes finished; none is cancelled.",
         "concurrency:", "  group: promote", "  cancel-in-progress: false", "",
         "permissions:", "  contents: write", "  checks: read", "", "jobs:"]
      end

      def job(lane)
        name = lane["name"]
        [
          "  promote_#{name}:", "    runs-on: ubuntu-latest", "    timeout-minutes: 15",
          "    # A run that did not finish green reports no commit worth promoting.",
          "    if: github.event.workflow_run.conclusion == 'success'", "    steps:",
          "      - uses: actions/checkout@v4", "        with:",
          "          ref: ${{ github.event.workflow_run.head_sha }}",
          "          # Full history: the fast-forward test needs both ends of the lane as real objects.",
          "          fetch-depth: 0",
          "      - uses: ./.github/actions/setup-ruby", "      - uses: ./.github/actions/hecks-environment",
          "      - name: Promote #{name}", "        env:", "          GH_TOKEN: ${{ github.token }}",
          "        run: >-",
          "          bundle exec exe/hecks promotion_run.promote lane=#{name}",
          "          commit=${{ github.event.workflow_run.head_sha }}",
          "          run=#{name}-${{ github.event.workflow_run.head_sha }} --confirm --wait"
        ]
      end

      # @param root [String] the checkout
      # @param files [Hash{String => String}] the projection
      # @return [Array<String>] ruleset files that no row of a guarded lane accounts for
      def leftover(root, files)
        Dir[File.join(root, RULESETS, "*.json")].reject { |path| files.key?(path) }
      end

      def write(path, text)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, text)
      end

      # @param stale [Array<String>] absolute paths that differ from the projection
      # @param files [Hash{String => String}] the projection
      # @param root [String] the checkout
      # @return [Integer] 0 when current, else 1 with the stale files on stderr
      def report(stale, files, root)
        if stale.empty?
          puts "lanes: #{files.size} files, every one current"
          return 0
        end

        warn "lanes: out of date: #{stale.map { |path| path.delete_prefix("#{root}/") }.join(', ')} " \
             "(run hecks regeneration_run.project_lanes)"
        1
      end

      # Compares the guarded lanes' rulesets with GitHub's, and with `confirm` makes GitHub match.
      #
      # @param confirm [Boolean] whether to create or update the rulesets
      # @param github [Hecks::Adapters::GithubRulesets] reads and writes GitHub's rulesets
      # @return [Integer] 0 when GitHub agrees (or was made to), else 1
      def live(confirm, github)
        found = lanes.select { |lane| lane["guarded"] == "yes" }.flat_map do |lane|
          projected = ruleset(lane)
          differences = github.differences(projected, github.named(projected["name"]))
          next [] if differences.empty?

          differences.each { |line| puts line }
          next differences unless confirm

          puts "#{projected['name']}: #{github.apply(projected)}"
          []
        end
        puts "lanes: GitHub holds every guarded lane's ruleset as projected" if found.empty? && !confirm
        return 0 if found.empty?

        warn "lanes: GitHub differs from the model (add --confirm to make it match)"
        1
      end
    end
  end
end
