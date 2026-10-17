# A route row names an edge function, and the site generator emits both the function and its attachment

**Status:** Proposed. Built on this branch, not released. Date: 2026-10-16.

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

   The function is part of what makes two behaviours equal, so a route with `edge:` is never folded into the behaviour of a broader route that has none, and a route is folded only into one with the same function. Two routes on one edge pattern that name different functions are refused, as two that resolve to different behaviours already are.

2. **The function is declared once, as a row.** A project adds `member` rows of a fifth value object of its route chapter, `EdgeFunction`, beside `Edge`, `EdgePolicy`, `EdgeOrigin` and `EdgeRule`. A row has a `name` (a CloudFormation logical id: letters and digits, at most 40, since the function's name in the account adds the stack name and CloudFront allows 64 characters) and a `kind`, a closed set in the Site chapter's `Route` aggregate. The first version has one kind:

   - `redirect_host`: the generator writes the function. Its fields are `host` (the canonical host, a literal lowercase hostname, not a template parameter), `aliases` (the hosts whose requests are redirected, comma separated) and `paths` (the exact paths the function watches, comma separated). A `GET` or `HEAD` request for one of the paths whose `Host` is one of the aliases is answered with a `302`, `Cache-Control: no-store`, to `https://<host><path>?<query>`, the query string carried over. Every other request passes through untouched: another method, another path (a trailing slash, a callback beneath the same prefix), the canonical host in any casing, a host that is not an alias, a request with no host.

   There is no `external` kind. A function the closed set does not cover is written by hand, outside the generated regions, until a second recurring need earns its own kind.

3. **The generator writes the function resource into a third region.** For each `EdgeFunction` row the projector returns a region, `edge_functions`, holding an `AWS::CloudFront::Function` (runtime `cloudfront-js-2.0`, `AutoPublish: true`, a name derived from the stack name and the row's name, so two stacks in an account do not collide) whose code is a fixed template, `redirect_host.js.tmpl`, with the row's three values filled in. The project adds the region to the `Resources` of its template once, by hand, as it did the other two; the generator never inserts one. It refuses, with a message that names the missing `BEGIN`/`END GENERATED site_cdn edge_functions` markers, a site that declares an `EdgeFunction` row whose template lacks the region, and a template that keeps the region when no `EdgeFunction` row exists, as `Templates` already refuses a missing or leftover `listener_rules` region. `--check` compares the region like the other two.

4. **Values are validated, never escaped.** The host and aliases must be lowercase hostnames of at least two labels (at most 253 characters), and each path must start with `/` and hold only letters, digits and `. _ ~ - /` (at most 200). Anything else is refused when the row is read, and refused again by the renderer, which is the last step before the text is written. Nothing is escaped, so no quote, backslash, newline, `</script>`, `${...}` or non-ASCII character can reach the JavaScript string, the YAML block or a CloudFormation expression. The values are written into the template with a single substitution pass, so a value cannot name a placeholder.

5. **Checks, all at generation time.** A route's `edge:` must be a logical id and must name an `EdgeFunction` row; a row's `name` is a logical id within the limit and unique, and no two names may derive the same function name; `kind` is in the set; `host`, each alias and each path match the shapes above, an alias differs from the host, and a row watches at least one path; an `EdgeFunction` row no route names is refused (a function nothing uses is a stale row); a route with `cdn: false` may not name one, since the edge never sees it. A route that names a function when the project declares no edge rows at all is refused too, rather than ignored. Every refusal is reported with the others, as the table's are.

6. **First version: the route-table CDN only.** The behaviours of `SiteCdn` carry the new field. The renderer is shared with the Fargate `cdn` setting, so the lines work there by construction, but that setting's own keys are not extended. The AwsBox edge is not touched. `Site::LiveEdge` (the comparison with a live distribution) does not learn about functions in this version: `check_live` compares what it compared before, and a function on a live behaviour is neither reported nor required.

7. **Status and headers are fixed.** The status is `302` and the response carries `Cache-Control: no-store`. A start path is a navigation, so a redirect that turns a `POST` into a `GET` is not reachable: only `GET` and `HEAD` are redirected, and every other method passes through to the origin untouched. A row has no field for either.

8. **The query string is rebuilt so it does not depend on how the runtime presents it.** The function rebuilds the query from `request.querystring`. Each key and value is percent-encoded only where it cannot stand in a query (a space, a control character, `&`, `=`, `#`, a non-ASCII character), and an existing `%XX` sequence is kept as it is. If the runtime hands the function raw text, the query is carried over byte for byte; if it hands the decoded text, the redirect is still a single well-formed location header that a line break or `&` cannot split. The one case the two readings disagree on is a decoded value that itself contains a literal percent sequence or `+`; that is the documented limit of the function until it is observed on a real distribution.

## Alternatives considered

- **(a) Only the `edge:` attribute, with the function written by hand.** This is the smallest change. Rejected as the whole answer: the project still keeps YAML by hand for a need every site with a registered callback host has, and the generator has to trust a name it can only check by reading the template as text.
- **An `external` kind, where the project owns the resource and the generator writes only the attachment.** Considered as the escape hatch for a function the closed set does not cover, and dropped from the first version. It needs the template read as text to check the resource exists, and the first need is fully covered by `redirect_host`. A second kind can be added to the closed set when it is needed.
- **(b) A new route kind `redirect` with a host condition.** The existing `redirect` kind answers from the origin (or the edge rule) with `redirect_to` for a path. A host condition does not fit a route, which is a path; the same path is served by one host and redirected on another, so it would need two rows on one path and the table refuses duplicate paths. It also moves the redirect back to the origin, which was the problem.
- **(c) Generate the function from the bluebook, with a `canonical_host` on the site table instead of a per-route attribute.** A site-wide canonical host is the right abstraction when every path must be on one host, but the need is a handful of paths: the other paths are meant to be served on every alias. A per-route attribute says which paths, and the function row says how. This decision takes the generation half of (c) and keeps the per-route half of (a), so neither alone is the design.
- **(d) Handle it outside the generated region.** Moving the start paths' behaviours out of the generated region means the generator no longer knows those paths exist: its shadowing check (a broader pattern before a specific one) cannot see them, and a regeneration silently orders a generated behaviour after a hand-written one that should win. Rejected.
- **Arbitrary function source in the bluebook** (a `code:` field). Rejected: JavaScript in a string in a model cannot be checked, and the closed `kind` set is where a second recurring need (a path rewrite, a header) earns its own kind.
- **The canonical host as a template parameter.** A parameter would need `Fn::Sub` around the function code, which collides with JavaScript's `${`, and would put a value the generator must validate outside the generator's reach. A literal in the row is validated where it is read.
- **Escaping hostile values instead of refusing them.** Rejected: the set of valid hostnames and paths is small and exact, so refusing anything else is both simpler and safer than choosing an escaping for three different contexts (a JavaScript string, a YAML block, a CloudFormation expression).
- **The generator inserting the `edge_functions` region.** Rejected: the two existing regions are placed by the project, which knows where its `Resources` and its distribution sit, and a generator that edits outside the markers breaks the guarantee that everything outside them is the project's.

## Consequences

- A host redirect is a few lines of rows: one `EdgeFunction` and an `edge:` on the start paths. Nothing is hand-kept except the markers.
- A missing function cannot reach CloudFormation as a surprise. `!GetAtt` on an undeclared logical id fails when the change set is created, before anything changes, and the generator refuses earlier than that. A function that exists but is wrong is a deploy-time fact: the generator can check the shape of the code, not what CloudFront does with it.
- Update and rollback follow the stack. The function and the distribution are updated in one change; the function's new code is live as soon as it publishes, ahead of the distribution's propagation, so for a short while the behaviours of the previous stack run the new code. A rollback restores the previous code. A `redirect_host` function that is only a comparison and a redirect is safe in both orders.
- A viewer-request function runs before the cache lookup and its redirect answer is not stored (`no-store`), so the cache key of every behaviour is unchanged. A function that rewrote the URI would change it; `redirect_host` does not.
- A request on a behaviour that names the function costs one function invocation, whatever its host. CloudFront bills per invocation; the function is attached to the start paths only, not the site.
- The default row may carry a function, which puts it on every request with no behaviour of its own. That is allowed and is the caller's choice.
- A function is an extra moving part to publish: a CloudFront function cannot be exercised without publishing it to a stage, so the first end-to-end proof of a new function is on a real distribution.
- A `Function` name is `<stack name>-<hyphenated row name>` and CloudFront caps a function name at 64 characters; the 40-character limit on the row name leaves room for a stack name of about 23 characters at the limit, and a longer stack name is a deploy-time failure, before the distribution changes.
- The Fargate `cdn` setting can name a function later by adding a key; the renderer needs no change.
- `check_live` does not see functions, so a function removed on the live side by hand is not reported until the next deploy.

## Testing

- The projection's golden (`spec/fixtures/site/template.yaml`, regenerated with `GOLDEN=rewrite` and read in the diff) gains an `EdgeFunction` row and an `edge:` on two routes in the studio sample project, so the attachment and the region are byte-checked.
- `spec/site_edge_function_spec.rb` covers the route attribute, every refusal of the `EdgeFunction` rows with its message, the folding rule, the lines with and without a function, the region and its YAML, hostile values (quotes, backslashes, `</script>`, `${}`, unicode, newlines) that must be refused, a template missing the region or keeping it without a row, and `--check` detecting drift in the region.
- `spec/site_edge_function_node_spec.rb` renders the function for the sample project and runs it under `node` against stub events (aliases and the apex, `GET` and `HEAD`, the exact watched paths, the query intact including repeated keys, empty values and encoded values, other methods, the canonical host in any casing, other paths, unknown and missing hosts, a decoded value that would split the header). The example is skipped, and says so, where `node` is not installed.
- Node alone is not enough. CloudFront compiles every regular expression of its JavaScript runtime with PCRE and refuses a pattern that names a surrogate code point (`SyntaxError: pcre_compile(...) failed: disallowed Unicode code point (>= 0xd800 && <= 0xdfff)`), which Node accepts. A function with such a pattern passes the node spec and then throws on every request once deployed, including the ones it would have passed through. The generated code therefore carries no surrogate in any pattern: the encoder walks the text one UTF-16 unit at a time and pairs surrogates in code (a lone one becomes `%EF%BF%BD`).
- `spec/site_edge_function_cloudfront_spec.rb` checks that, in two parts. A static guard always runs: it renders the function and fails, naming CloudFront's error, if any regular expression literal or `new RegExp` holds a code point in U+D800..U+DFFF, written as an escape or as itself. An example tagged `:cloudfront`, left out unless `HECKS_CLOUDFRONT_TEST=1` is set and the AWS CLI has credentials, creates a throwaway function (named `tmp-hecks-edge-test-<random>`, development stage, never attached or published), runs `aws cloudfront test-function` for a pass-through, a redirect with a query and an astral character, and deletes the function in an `ensure`.
- `test-function` runs the code in CloudFront's runtime but hands it the event object it was given, so it does not show whether a real viewer request carries a query value raw or decoded; that stays an observation of the first deploy (Rollout 5). It also reorders a query string's keys, which the function does not depend on.

## Rollout

1. The change ships with the route-table projection; a project that adds no `EdgeFunction` row and no `edge:` generates the same text as before, byte for byte.
2. A project adopts it by adding the `edge_functions` region to its template (once, by hand, empty between the markers), the row and the `edge:` fields, then regenerating and reading the diff.
3. Before the first deploy, the project creates the change set and reads it: the function is a create, the distribution an update that adds `FunctionAssociations` to the named behaviours only.
4. After deploy, the project requests a start path on a non-registered alias and expects the redirect with the query intact, and a request on the registered host and expects the origin's own answer.
5. The query-string behaviour of the real runtime (raw or decoded values) is observed on that first deploy and recorded; the function is correct for either, within the limit in Decision 8.
