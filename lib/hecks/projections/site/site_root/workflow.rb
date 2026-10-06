# frozen_string_literal: true

module Hecks
  module Projections
    module Site
      module SiteRoot
        # The workflow that keeps the generated files current, as a `format` template.
        module Workflow
          # The file, with `%<name>s` placeholders for the row's values.
          TEXT = <<~YAML
            %<banner>s
            # Two checks, neither needing AWS or a database:
            #
            #   1. the generated files are current: `%<script>s --check` regenerates them with the hecks
            #      gem the Gemfile.lock pins and exits 1, naming each file, if a row was edited without
            #      regenerating or a generated file was hand-edited;
            #   2. `%<test>s`, which holds the generated code to what the hand-written code does.
            name: %<name>s

            on:
              push:
                branches: [main]
                paths:
            %<paths>s
              pull_request:
                paths:
            %<paths>s
              # Lets a GitHub merge queue run this check on each queued PR (paths do not apply to merge_group).
              merge_group:
              workflow_dispatch: {}

            permissions:
              contents: read

            jobs:
              routes-current-and-parity:
                runs-on: ubuntu-24.04
                timeout-minutes: 15

                steps:
                  - uses: actions/checkout@11d5960a326750d5838078e36cf38b85af677262 # v4

                  - uses: ruby/setup-ruby@14594264cd68ce8a2345dd349bc3d138a4ef85c8 # v1
                    with:
                      ruby-version: %<ruby>s
                      bundler-cache: true
                      working-directory: %<gem_dir>s

                  - name: The generated files are current
                    run: %<script>s --check

                  - uses: actions/setup-node@49933ea5288caeca8642d1e84afbd3f7d6820020 # v4
                    with:
                      node-version: %<node>s

                  %<install_steps>s

                  - name: Parity between the generated code and the hand-written code
                    run: %<test>s
          YAML
        end
      end
    end
  end
end
