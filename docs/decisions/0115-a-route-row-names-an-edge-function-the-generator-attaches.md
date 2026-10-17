# A route row names an edge function, and the site generator emits both the function and its attachment

**Status:** Proposed. Not built. Date: 2026-10-16.

## Context

`hecks site site_projection.project_site` writes the CloudFront behaviours of a site's distribution from its `Route` rows, between the `BEGIN`/`END GENERATED site_cdn behaviors` markers of a template the project owns. A behaviour it writes has a path pattern, an origin, viewer protocol, methods, compression and up to three policies. It cannot write `FunctionAssociations`, so a site cannot attach a viewer-request function to a path from its route table.

The need is concrete and recurring. A sign-in flow whose callback is registered on one host needs requests for its start paths that arrive on any other alias of the same site to be redirected to the registered host at the edge. The alias is a valid name for the site; the start path is the only place it must not be served from, because the state the flow sets (a cookie, a nonce) would then live on a host the callback never returns to. The origin cannot do this: by the time it sees the request the response is already shaped for the alias, and a redirect that every alias costs a trip to the origin.

Today the project writes the `AWS::CloudFront::Function` by hand and the association by hand, which means the association has to sit inside a generated region, where the next run erases it. The only fix available is to carve the start paths out of the route table and write their behaviours by hand too, which gives up the table's one guarantee: a path is named once.

Where the behaviour YAML comes from (verified in the source):

- `Hecks::Projections::Site::Edge` (`lib/hecks/projections/site/edge.rb`) reads the `Route` rows and the `Edge`, `EdgePolicy`, `EdgeOrigin` and `EdgeRule` rows, and `Edge::Behaviours` (`edge/behaviours.rb`) turns each CDN route into a behaviour hash. It drops a route whose behaviour equals the one that would match its path anyway.
- `Hecks::Projections::Site::SiteCdn` renders the hashes through `Projections::Deploy::Fargate::Cdn.behavior_lines` (`lib/hecks/projections/deploy/fargate/cdn/lines.rb`). That renderer is shared with the Fargate `cdn` setting; it is the only place a behaviour's lines are written.
- `Tools::SiteRoutes::Templates` puts each region the projector returns between its markers, and `--check` compares the rewritten template with the file on disk.
- The AwsBox edge (`lib/hecks/projections/deploy/box/templates/edge.yaml.tmpl`) is one distribution with a single default behaviour and no per-path rows. It does not use the route table.

## Decision

1. **A route row may name an edge function.** A new optional field `edge:` on a `Route` member is the logical id of a function. A route with `edge:` gets this under its behaviour, and the default row `/*` may carry one too:

   ```yaml
   FunctionAssociations:
     - EventType: viewer-request
       FunctionARN: !GetAtt HostRedirect.FunctionARN
   ```

   The function is part of what makes two behaviours equal, so a route with `edge:` is never folded into the behaviour of a broader route that has none, and a route is folded only into one with the same function.

2. **The function is declared once, as a row.** A project adds `member` rows of a fifth value object of its route chapter, `EdgeFunction`, beside `Edge`, `EdgePolicy`, `EdgeOrigin` and `EdgeRule`. A row has a `name` (a CloudFormation logical id: letters and digits) and a `kind`, a closed set in the Site chapter's `Route` aggregate:

   - `redirect_host`: the generator writes the function. Its extra fields are `host` (the host requests are sent to) and `status` (`302` by default; `301`, `307` or `308`). A request whose `Host` is already `host` passes through untouched; any other host is answered with a redirect to `https://<host><path>?<query>`, with the query string carried over. This is the host redirect of the Context, and the one kind the first version writes.
   - `external`: the project owns the resource. The generator writes only the attachment, and refuses at generation time unless the template, read as text, declares a resource with that logical id. It is the escape hatch for a function the closed set does not cover.

3. **The generator writes the function resource into a second region.** For a `redirect_host` row the projector returns a new region, `edge_functions`, holding an `AWS::CloudFront::Function` (runtime `cloudfront-js-2.0`, `AutoPublish: true`, a name derived from the stack name so two stacks in an account do not collide) whose code is a fixed template with the row's `host` and `status` filled in. The region goes in the template's `Resources`. A template needs it only when a `redirect_host` row exists, as `listener_rules` is needed only with a load balancer. A project with `external` rows alone has no such region, and a leftover one is refused, as a leftover `listener_rules` region is.

4. **Checks, all at generation time.** A route's `edge:` must be a logical id and must name an `EdgeFunction` row; a row's `name` is unique; a `redirect_host` row needs a `host` that is a hostname and a `status` of the four; an `external` row's resource must be in the template; an `EdgeFunction` row no route names is refused (a function nothing uses is a stale row). A route with `cdn: false` may not name one, since the edge never sees it. Every refusal is reported with the others, as the table's are.

5. **First version: the route-table CDN only.** The behaviours of `SiteCdn` carry the new field. The renderer is shared with the Fargate `cdn` setting, so the lines work there by construction, but that setting's own keys are not extended. The AwsBox edge is not touched. `Site::LiveEdge` (the comparison with a live distribution) learns to report whether a behaviour has a viewer-request function, and nothing about its ARN, which the live side holds resolved.

## Alternatives considered

- **(a) Only the `edge:` attribute, with the function written by hand.** This is the smallest change, and it is what `external` keeps. Rejected as the whole answer: the project still keeps YAML by hand for a need every site with a registered callback host has, and the generator has to trust a name it can only check by reading the template as text.
- **(b) A new route kind `redirect` with a host condition.** The existing `redirect` kind answers from the origin (or the edge rule) with `redirect_to` for a path. A host condition does not fit a route, which is a path; the same path is served by one host and redirected on another, so it would need two rows on one path and the table refuses duplicate paths. It also moves the redirect back to the origin, which was the problem.
- **(c) Generate the function from the bluebook, with a `canonical_host` on the site table instead of a per-route attribute.** A site-wide canonical host is the right abstraction when every path must be on one host, but the need is a handful of paths: the other paths are meant to be served on every alias. A per-route attribute says which paths, and the function row says how. This decision takes the generation half of (c) and keeps the per-route half of (a), so neither alone is the design.
- **(d) Handle it outside the generated region.** Moving the start paths' behaviours out of the generated region means the generator no longer knows those paths exist: its shadowing check (a broader pattern before a specific one) cannot see them, and a regeneration silently orders a generated behaviour after a hand-written one that should win. Rejected.
- **Arbitrary function source in the bluebook** (a `code:` field). Rejected: JavaScript in a string in a model cannot be checked, and the closed `kind` set is where a second recurring need (a path rewrite, a header) earns its own kind.

## Consequences

- A host redirect is a few lines of rows: one `EdgeFunction` and an `edge:` on the start paths. Nothing is hand-kept.
- A missing function cannot reach CloudFormation as a surprise. `!GetAtt` on an undeclared logical id fails when the change set is created, before anything changes, and the generator refuses earlier than that. A function that exists but is wrong is a deploy-time fact: the generator can check the shape of the code, not what CloudFront does with it.
- Update and rollback follow the stack. The function and the distribution are updated in one change; the function's new code is live as soon as it publishes, ahead of the distribution's propagation, so for a short while the behaviours of the previous stack run the new code. A rollback restores the previous code. A `redirect_host` function that is only a comparison and a redirect is safe in both orders.
- A viewer-request function runs before the cache lookup and its redirect answer is not stored, so the cache key of every behaviour is unchanged. A function that rewrote the URI would change it; `redirect_host` does not.
- A request on the registered host costs one function invocation. CloudFront bills per invocation; the function is attached to the start paths only, not the site.
- The default row may carry a function, which puts it on every request with no behaviour of its own. That is allowed and is the caller's choice.
- A function is an extra moving part to publish: a CloudFront function cannot be exercised without publishing it to a stage, so the first end-to-end proof of a new function is on a real distribution.
- The Fargate `cdn` setting can name a function later by adding a key; the renderer needs no change.

## Testing

- The projection's golden (`spec/fixtures/site/template.yaml`, regenerated with `GOLDEN=rewrite` and read in the diff) gains an `EdgeFunction` row and an `edge:` route in the studio sample project, so the attachment and the region are byte-checked.
- `spec/site_edge_spec.rb` gains refusals: an `edge:` naming no row; a duplicate name; a `redirect_host` row with no host or a bad status; an `external` row whose resource is absent from the template; a row no route names; a route with `cdn: false` and an `edge:`. It also gains the folding rule: a route with `edge:` under a broader route with none keeps its behaviour, and a route with the same function as its cover does not.
- The generated function code is a fixed template, so a spec checks its text exactly. Where `node` is on the path, one example runs it against a fake event (same host passes through; another host redirects, the path and query intact), so the logic is exercised without publishing. The example is skipped, and says so, where `node` is absent.
- `--check` is covered by the existing example that names a hand-edited region, repeated for `edge_functions`.
- Nothing here can be run against CloudFront from the suite. The proof on a real distribution is a rollout step, not a spec.

## Rollout

1. The change ships with the route-table projection; a project that adds no `EdgeFunction` row and no `edge:` generates the same text as before, byte for byte.
2. A project adopts it by adding the `edge_functions` region to its template (once, by hand, empty between the markers), the row and the `edge:` fields, then regenerating and reading the diff.
3. Before the first deploy, the project creates the change set and reads it: the function is a create, the distribution an update that adds `FunctionAssociations` to the named behaviours only.
4. After deploy, the project requests a start path on a non-registered alias and expects the redirect, and a request on the registered host and expects the origin's own answer. `site_projection.check_live` reports the behaviours as having a function.
5. The `external` kind is the way out for any site that outgrows `redirect_host`; nothing in the first version prevents moving a row between kinds.
