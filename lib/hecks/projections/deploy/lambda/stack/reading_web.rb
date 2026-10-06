module Hecks
  module Projections
    module Deploy
      module Lambda
        class Stack
          # Reads the facts about the domain's own web function from the files beside the world.
          # Included into `Stack`; each step is one move of its constructor.
          module ReadingWeb
            private

            # Opt-in by file presence: a domain wanting its own web app on Lambda drops a
            # `lambda_handler.rb` (the Rack-to-Function-URL-event adapter Sinatra runs through) at
            # its own root. No separate .world verb.
            def read_web
              @web_handler_present = File.exist?(File.join(domain, "lambda_handler.rb"))
              check_one_web_story
              @pg_version = read_pg_version
              @web_logical_id = "WebFunction"
              read_web_paths
              read_google_oauth
            end

            # Read from the domain's own Gemfile.lock, not hardcoded: the `patch-pg-native` build
            # recipe must fetch the same pg version Bundler resolved, or the from-source extension
            # can drift from it. `dispatch "None"` reads this project's own root Gemfile.lock, not
            # the domain's: the domain has no Gemfile of its own to bundle.
            def read_pg_version
              return nil unless web_handler_present

              File.read(File.join(dispatch_none ? root : domain, "Gemfile.lock"))[/^\s+pg \(([\d.]+)\)/, 1]
            end

            # `dispatch "None"` means the domain alone has no Gemfile/lib/hecks to zip, so CodeUri
            # is `root` there instead.
            def read_web_paths
              @web_code_uri = dispatch_none ? root : domain
              @web_handler_relpath = dispatch_none ? "#{domain}/lambda_handler" : "lambda_handler"
            end

            # `.env.local` is the domain's gitignored local-dev secrets file, read only to detect
            # the key is present; `make sync-google-oauth` syncs the real value into Secrets Manager
            # at deploy time.
            def read_google_oauth
              env_file = File.join(domain, ".env.local")
              @google_oauth_present = (web_handler_present || rust_web) && File.exist?(env_file) &&
                                      File.read(env_file).match?(/^GOOGLE_CLIENT_ID=\S/)
            end
          end
        end
      end
    end
  end
end
