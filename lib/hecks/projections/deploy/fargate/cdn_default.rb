module Hecks
  module Projections
    module Deploy
      module Fargate
        # The default distribution's text; `cdn.rb` documents the module.
        module Cdn
          module_function

          # The distribution a stack gets when its world sets no `cdn` options: HTTPS in
          # front of the HTTP-only ALB, caching disabled since every route is session-driven.
          def default_yaml(alb_id:, distribution_id:)
            <<~DEFAULT
              # Real HTTPS (the ALB's own Listener above is HTTP-only —
              # nothing else in this stack terminates TLS) and, just as
              # important, the ONE safe default this generator can offer
              # for caching it has no way to reason about: Managed-
              # CachingDisabled. This domain's own routes — including
              # every hecks-native /login, /logout, /auth/google(/callback),
              # /admin/members request (web.rs's own auth_gate/auth_route,
              # generic across every domain, not just this one's own
              # dispatch commands) — are all session-cookie-driven, and
              # this generator has no way to tell which of a domain's own
              # paths would ever be safe to cache. Found live, the hard
              # way (2026-09-21): a hand-authored CloudFront
              # stack applied the OPPOSITE default — a custom, cookie-
              # blind cache policy with a 90-120s TTL — and it served one
              # signed-in session's own response (a short-lived SSO
              # handoff token among them) back to a different, unrelated
              # request within that window. A domain that DOES know one
              # of its own paths is genuinely safe to cache (a public,
              # non-personalized page) adds its own more specific
              # CacheBehavior through the `cdn` setting's `behaviors`,
              # never by loosening this one.
              #{distribution_id}:
                Type: AWS::CloudFront::Distribution
                Properties:
                  DistributionConfig:
                    Enabled: true
                    HttpVersion: http2
                    # No ACM/custom domain by default — CloudFront requires
                    # an ACM cert in us-east-1 specifically to attach a
                    # custom Aliases entry, a real cross-region dependency
                    # this generator can't assume. CloudFront's own default
                    # *.cloudfront.net certificate/hostname are what
                    # Outputs.CloudFrontDomain below reports; the `cdn`
                    # setting's `aliases` and `certificate_arn` attach a
                    # real domain.
                    ViewerCertificate:
                      CloudFrontDefaultCertificate: true
                    Origins:
                      - Id: #{alb_id}Origin
                        DomainName: !GetAtt #{alb_id}.DNSName
                        CustomOriginConfig:
                          OriginProtocolPolicy: http-only
                          HTTPPort: 80
                          HTTPSPort: 443
                    DefaultCacheBehavior:
                      TargetOriginId: #{alb_id}Origin
                      ViewerProtocolPolicy: redirect-to-https
                      Compress: true
                      AllowedMethods: [GET, HEAD, OPTIONS, PUT, PATCH, POST, DELETE]
                      CachedMethods: [GET, HEAD]
                      # Managed-CachingDisabled — see this resource's own
                      # header comment for why nothing else is safe here
                      # by default.
                      CachePolicyId: 4135ea2d-6df8-44a3-9df3-4b5a84be39ad
                      # Managed-AllViewer — forwards every cookie/header/
                      # query string through uncached, so rust/host's own
                      # session-cookie-based auth sees the real request
                      # exactly as the browser sent it.
                      OriginRequestPolicyId: 216adef6-5c7f-47e4-b989-5492eafa07d3
            DEFAULT
          end
        end
      end
    end
  end
end
