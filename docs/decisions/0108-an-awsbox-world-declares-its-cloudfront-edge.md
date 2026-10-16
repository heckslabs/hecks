# An AwsBox world declares its CloudFront edge

**Status:** Proposed. Built: the `cdn` setting, `BoxTarget.Declare`'s `cdn_aliases`, the `edge.yaml` and `edge.mk` projection and the
prefix-list lookup in `make stacks`. Date: 2026-10-15.

## Context

`deployed_to("AwsBox")` generates the database stack, the box stack, the proxy and the scripts that roll the box
([ADR 0085](0085-aws-box-is-a-deploy-kind-one-ec2-box-and-one-rds-instance.md)). It generates nothing in front of the box.
Every site that runs on a box also runs a CloudFront distribution in front of it, and each wrote that template by hand:
the distribution, its aliases, one origin (the box's `AppOriginDomain`) carrying the origin-secret header, no caching and
the all-viewer origin request policy, and an ACM certificate ARN as a parameter. A third copy, for the platform console and
its second host name, would have been the same file again.

The box stack's `CdnPrefixListId` parameter defaults to blank, and a blank prefix list leaves the box with no inbound rule
at all. The generated `make stacks` never passed it. A box deployed with that Makefile accepted nothing from CloudFront, and
the distribution answered every request with a 504 that named no cause. The prefix list's id also differs in every region,
so it cannot be written into a template.

## Decision

1. **The edge is a setting of the box world, and it is opt-in.** `cdn({ aliases: ["platform.example.com", "auth.example.com"] })`
   inside `deployed_to("AwsBox")`. A world that does not name it generates exactly the files it did before.
2. **Bluebook first.** `BoxTarget` gains an optional `cdn_aliases` (a list of `CdnAlias` value objects, each a lowercase host
   name of at most 253 characters), and `BoxTarget.Declare` sets it. A bad alias is refused there, with the block named, before any
   projection runs. The projection checks only what is not a fact about a name: the `cdn` hash has `aliases` and nothing else,
   the list is not empty, and the world also declares `origin_header` and `origin_secret`. A box that admits CloudFront's
   addresses without a guard that refuses every other caller would serve any CloudFront customer.
3. **The projection writes `edge.yaml` and `edge.mk`.** One distribution, retained when the stack is deleted. Its aliases are
   the default of a `DomainNames` parameter, so a deploy can still override them. Its origin is the `AppOriginDomain` parameter
   over plain http, with the origin header's value read by CloudFormation from Secrets Manager (`{{resolve:secretsmanager:...}}`),
   so the secret is never in the file or on a command line. Caching is disabled and the all-viewer request policy forwards what
   the viewer sent. The certificate is a parameter, `CertificateArn`, which must be an ACM ARN in us-east-1: DNS validation is a
   step a person performs, so the generator never creates one.
4. **`make stacks` closes the prefix-list trap.** For a world with `cdn`, the Makefile looks the AWS-managed
   `com.amazonaws.global.cloudfront.origin-facing` list up by name in the world's region, passes its id as `CdnPrefixListId`,
   and first refuses to run when the lookup finds nothing, before any stack changes. `make edge CERTIFICATE_ARN=...` then deploys
   the edge stack, reading `AppOriginDomain` from the box stack.
5. **Not in this decision.** Per-path behaviours, cache and response-header policies, a second origin and certificate creation.
   A site that needs them keeps its own template and does not set `cdn`.
6. **Rust.** The generator is Ruby. The Deploy chapter that `BoxTarget` lives in is resolved by `rust/build` like any other
   bluebook, and the change uses only constructs bluebooks already use (an optional `list_of` of value objects, portable
   invariants), so no Rust source changes.

## Consequences

- A world with `cdn` gains two files and an `include edge.mk` line, and its `make stacks` fails early in a region that has no
  such prefix list.
- A world without `cdn` still deploys the box with a blank `CdnPrefixListId` unless the operator passes one; that remains the
  site's choice (a Cloudflare Tunnel box wants no inbound).
- A site that already runs a hand-written edge adopts this by adding `cdn` and importing its distribution into the generated stack
  or by leaving its stack alone; a stack name that differs from `<prefix>-<name>-edge` is a decision for that site.
