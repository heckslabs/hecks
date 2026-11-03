# frozen_string_literal: true

require "json"
require "open3"
require_relative "../cli/qa_main_gate"
require_relative "../cli/declared"

module Hecks
  module Adapters
    # The `ImageRoll` port's adapter. `classify` reads a green commit of embryonaut_platform's
    # change set
    # and answers whether only the console container's inputs changed; `roll` builds the console
    # image
    # and rolls it with the platform's own `make deploy-service`. Both answer the event their
    # policy
    # waits for, or raise, which the runtime records as the refusal.
    class ImageRoll
      # The repository this adapter reads changes from, and the one service it rolls. Which repository
      # and branch roll at all is the `RollRepo` and `RollBranch` declaration, which the chain's
      # `Consider` command enforces.
      PLATFORM_REPO = "heckslabs/embryonaut_platform"
      APP = "console"

      # The default platform checkout the roll builds from; `platform_root:` overrides it.
      PLATFORM_ROOT = File.expand_path("~/Projects/embryonaut_platform")

      # Raised when a step refuses; its message is the refusal's reason.
      class Refused < RuntimeError; end

      # The outside-world commands; a spec injects a stub in their place.
      module Commands
        module_function

        # @return [Array(String, Boolean)] the build's output and whether it exited 0
        def docker_build(dir)
          output, status = Open3.capture2e("docker", "build", "--platform", "linux/arm64",
                                           "-t", "embryonaut-platform-console:latest", ".", chdir: dir)
          [output, status.success?]
        end

        # @return [Array(String, Boolean)] the roll's output and whether it exited 0
        def deploy_service(dir)
          output, status = Open3.capture2e("make", "deploy-service", "SERVICE=#{APP}",
                                           chdir: File.join(dir, "deploy-aws/box-generated"))
          [output, status.success?]
        end
      end

      # Whether one changed path is part of the console container's inputs, as the `ImageInput` rows of
      # the QualityControl bluebook declare them.
      #
      # @param path [String] a repository-relative path
      # @param source [#bluebook, nil] the booted ledger, or nil to read this checkout's bluebook
      # @return [Boolean]
      def self.image_path?(path, source = nil)
        inputs = Hecks::QualityControlCli::Declared.rows(source, "ImageRoll", "ImageInput")
        covered = ->(kind) { inputs.select { |row| row[:kind] == kind }.map { |row| row[:path] } }
        return false if covered.("outside").any? { |dir| path.start_with?(dir) }

        covered.("file").include?(path) || covered.("dir").any? { |dir| path.start_with?(dir) }
      end

      # @param root [String, nil] the Hecks checkout, whose QA ledger holds the quick gate's
      # records
      # @param platform_root [String] the embryonaut_platform checkout the roll builds from
      # @param commands [Module] the outside-world commands; a spec injects a stub
      # @param registry [Runtime::Registry, nil] the booted registry whose QualityControl bluebook
      #   declares the console image's inputs; this checkout's bluebook is read when nil
      # @param ledger [#query, nil] the QA ledger the quick gate's records are read from; booted
      # from
      #   `root` when nil
      def initialize(root: nil, platform_root: PLATFORM_ROOT, commands: Commands, ledger: nil, registry: nil, **)
        @registry = registry
        @root = root || Dir.pwd
        @platform_root = platform_root
        @commands = commands
        @ledger = ledger
      end

      # Classifies one green commit: `image` when every changed path is a container input, `infra`
      # otherwise. The classifier reads no quick gate: an image-only commit rolls on its green
      # remote CI alone, and an infra commit is held for a person.
      #
      # @param commit [Hash, String] the commit
      # @param branch [Hash, String] the branch; `RollBranch` allows only main, which `Consider` enforces
      # @param repo [Hash, String] `owner/name`; `RollRepo` allows only embryonaut_platform
      # @return [Hash] `commit`, `app`, `kind` and `paths`
      def classify(commit:, branch:, repo:, **)
        sha = value_of(commit)
        paths = changed_paths(sha)
        kind = image_only?(paths) ? "image" : "infra"
        { commit: wrap(sha), app: wrap(APP), kind: wrap(kind), paths: wrap(paths.join("\n")) }
      end

      # Builds the console image and rolls it. An infra commit rolls only when the quick gate on
      # record for it is green; a failed build refuses; a failed roll answers `failed`.
      #
      # @param commit [Hash, String] the commit being rolled
      # @param app [Hash, String] the service; only the console rolls
      # @return [Hash] `commit`, `app` and `status` (`done` or `failed`)
      def roll(commit:, app:, **)
        refuse_infra_without_gate(value_of(commit))
        output, built = @commands.docker_build(@platform_root)
        raise Refused, "the console image did not build: #{tail(output)}" unless built

        output, rolled = @commands.deploy_service(@platform_root)
        { commit: wrap(value_of(commit)), app: wrap(value_of(app)), status: { value: rolled ? "done" : "failed" },
          output: output }
      end

      private

      # An infra commit is the fail-closed case: its roll needs the quick gate on record green. An
      # image-only commit rolls on remote CI's green verdict alone.
      def refuse_infra_without_gate(sha)
        return if image_only?(changed_paths(sha))
        return if gate_green?(sha)

        raise Refused, "#{sha[0, 7]} changes paths outside the console image and the quick gate on record for it is not green"
      end

      def image_only?(paths) = paths.all? { |path| self.class.image_path?(path, @registry) }

      def changed_paths(sha)
        output, status = Open3.capture2e("gh", "api", "repos/#{PLATFORM_REPO}/commits/#{sha}",
                                         "--jq", ".files[].filename")
        raise Refused, "gh could not list the changes of #{sha[0, 7]}: #{output.lines.first&.strip}" unless status.success?

        paths = output.lines.map(&:strip).reject(&:empty?)
        raise Refused, "#{sha[0, 7]} changes no path" if paths.empty?

        paths
      end

      # The most recent quick-gate record for the commit, read from the QA ledger. A commit with no
      # record is not green: the gate has not said so.
      def gate_green?(sha)
        row = ledger.query("QualityControl::MainCheck.All").find { |check| check[:reference][:value] == sha }
        row&.dig(:verdict, :value) == "green"
      end

      def ledger = @ledger ||= Hecks.boot(File.join(@root, "qa/bluebook"))

      def wrap(value) = { value: value }

      # The last lines of a command's output, which is where its failure is named.
      def tail(text) = text.lines.last(3).join

      def value_of(value) = value.is_a?(Hash) ? value.transform_keys(&:to_s)["value"] : value
    end
  end
end
