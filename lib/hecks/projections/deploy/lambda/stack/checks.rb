module Hecks
  module Projections
    module Deploy
      module Lambda
        class Stack
          # The combinations of settings a Lambda stack refuses, each before any file is written.
          # Included into `Stack`.
          module Checks
            private

            # AWS::WAFv2::WebACL with Scope: CLOUDFRONT is refused by CloudFormation outside
            # us-east-1; refused here before writing a file.
            def check_pii_region
              return unless pii_detected && region != "us-east-1"

              raise ArgumentError, "#{world_file} marks a field \"pii\" but deployed_to(\"AwsLambda\") sets region " \
                                   "#{region.inspect} — a CloudFront-scoped WAFv2 WebACL can only be created in " \
                                   "us-east-1. Set region \"us-east-1\", or remove the pii marking if this domain " \
                                   "genuinely holds none."
            end

            # A domain declares one web story, not both.
            def check_one_web_story
              return unless rust_web && web_handler_present

              raise ArgumentError, "#{domain} declares both web \"Rust\" (#{world_file}) and a lambda_handler.rb " \
                                   "(#{File.join(domain, "lambda_handler.rb")}) — pick one."
            end

            def check_web
              check_shared_handler
              check_dispatch_none
            end

            # A shared-instance Ruby WebFunction needs cross-stack DATABASE_URL wiring this
            # generator doesn't build yet.
            def check_shared_handler
              return unless shared && web_handler_present

              raise ArgumentError, "#{domain} declares both database \"Shared\" and a lambda_handler.rb — " \
                                   "a shared-instance Ruby WebFunction isn't supported yet."
            end

            # `dispatch "None"` means WebFunction is the domain's only Lambda.
            def check_dispatch_none
              return unless dispatch_none

              unless web_handler_present
                raise ArgumentError, "#{domain} declares dispatch \"None\" but has no lambda_handler.rb — dispatch " \
                                     "\"None\" means no rust/host dispatch Lambda at all, so a WebFunction " \
                                     "(lambda_handler.rb) has to exist to be the domain's only Lambda."
              end
              return unless rust_web

              raise ArgumentError, "#{domain} declares both dispatch \"None\" and web \"Rust\" — dispatch \"None\" " \
                                   "already means there is no rust/host Lambda for rust_web's own in-process web " \
                                   "UI to run inside."
            end
          end
        end
      end
    end
  end
end
