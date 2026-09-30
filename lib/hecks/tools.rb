# frozen_string_literal: true

module Hecks
  # The repository's command-line tools as library code: the comment linters, the regeneration
  # run, the deploy generators and the conformance matrix.
  #
  # Each tool is a module with `main(argv, root:)` that prints to `$stdout` and `$stderr` and
  # refuses with `abort` or `exit`, as the script it replaced did, and answers an exit status. A
  # `bin/` script is a shim that requires its tool and calls it; an adapter runs the same tool in
  # this process under `Adapters::ConsoleCapture`. `require "hecks"` loads none of them: each is
  # required by the command that needs it.
  module Tools
    # The checkout this file lives in, which a tool works on when it is given no other.
    ROOT = File.expand_path("../..", __dir__)

    # Each tool by the name of the `bin/` script it replaced: the file that defines it, and its
    # constant.
    REGISTRY = {
      "standardize_comments"           => ["tools/comment_style", "CommentStyle"],
      "standardize_comments_rust"      => ["tools/rust_comment_style", "RustCommentStyle"],
      "regen_codegen_domains"          => ["tools/regeneration_run", "RegenerationRun"],
      "argument_gate_matrix"           => ["tools/argument_gate_matrix", "ArgumentGateMatrix"],
      "project_deploy"                 => ["tools/deploy_recipe", "DeployRecipe"],
      "lint_deploy_recipes"            => ["tools/deploy_recipe_lint", "DeployRecipeLint"],
      "project_oidc"                   => ["tools/oidc_manifests", "OidcManifests"],
      "project_tenant"                 => ["tools/tenant_provisioning", "TenantProvisioning"],
      "fuzz"                           => ["tools/fuzz_sweep", "FuzzSweep"],
      "generate"                       => ["tools/sequence_script", "SequenceScript"],
      "corpus"                         => ["tools/corpus_report", "CorpusReport"],
      "evolve"                         => ["tools/evolve_run", "EvolveRun"],
      "query_ir"                       => ["tools/query_ir_run", "QueryIrRun"],
      "codemod_hoist_local_givens"     => ["tools/hoist_local_givens", "HoistLocalGivens"],
      "codemod_implicit_append_fields" => ["tools/drop_implicit_append_fields", "DropImplicitAppendFields"]
    }.freeze

    module_function

    # @param name [String] a script's name, as under `bin/`
    # @return [Boolean] whether the script's body lives here
    def tool?(name) = REGISTRY.key?(name)

    # Loads a tool and returns it.
    #
    # @param name [String] a script's name, as under `bin/`
    # @return [Module] the tool, which answers `main(argv, root:)`
    # @raise [KeyError] when no tool replaced a script of that name
    def fetch(name)
      file, constant = REGISTRY.fetch(name)
      require File.join(__dir__, file)
      const_get(constant)
    end

    # Runs a tool as the `bin/` script did and exits with its status. Paths in `argv` are read
    # from the directory the caller stands in.
    #
    # @param name [String] a script's name, as under `bin/`
    # @param argv [Array<String>] the arguments the script took
    # @return [void]
    def script(name, argv)
      exit(fetch(name).main(argv) || 0)
    end

    # Runs a tool from a checkout's root in this process.
    #
    # @param name [String] a script's name, as under `bin/`
    # @param argv [Array<String>] the arguments the script took
    # @param root [String] the checkout to work on
    # @return [Integer] the exit status: 0 when the tool ends normally
    def run(name, argv, root: ROOT)
      Dir.chdir(root) { fetch(name).main(argv, root: root) || 0 }
    rescue SystemExit => e
      e.status
    end
  end
end
