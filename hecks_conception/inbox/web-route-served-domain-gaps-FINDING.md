# FINDING: `:web` route gaps block a served user-domain admin page

_Discovered 2026-06-27 while building a bluebook-native admin surface for
Deciderate (queries in the bluebook, the page served by a hecksagon `:web`
route). Two independent runtime gaps in `rust/src` make it unbuildable without
a Rust change. Filed for the autophagy/runtime lane._

## Gap 1 — `:web` `template_path` is repo_root-relative, not served-dir-relative

`web_adapter::build_route` stores `template_path: Some(repo_root.join(&v))`, and
`repo_root = repo_root_of_binary()` (the hecks install). So a hecksagon served
via `storehouse serve <dir>` that declares `template_path: "admin.html.template"`
resolves it to `<hecks-repo>/admin.html.template`, NOT `<served-dir>/...`. The
route registers, but `GET /admin` returns 404 because the template can only live
inside the hecks repo.

This is fine for FRAMEWORK surfaces (LivingDiagram's template lives in the hecks
repo) but blocks any USER domain from shipping its own `:web` template.
Serializers already resolve sibling files against `served_dir` (`user_flows`
reads `<served_dir>/inbox/*.md`); templates should too. Likely fix: resolve
`template_path` against `served_dir` (or try served_dir first, repo_root
fallback) in `build_route` / at render time.

Repro: a 1-domain served dir with `adapter :web, get: "/x", template_path:
"x.html"` + an `x.html` in that dir → route lists in boot, `GET /x` 404s.

## Gap 2 — `persisted_by` binds + a `:web` adapter in the SAME hecksagon suppress the `:web` route

A hecksagon that contains BOTH `Aggregate.persisted_by("Heki")` binds AND an
`adapter :web, ...` keyword-form route, served alongside its matching domain
bluebook, fails to register the `:web` route (boot shows the framework routes
only). The same `:web` adapter registers fine when alone in a binds-free
hecksagon. Bisecting was non-deterministic across minimal repros vs the real
file, which suggests an ordering/consumption interaction in the parse loop
(`hecksagon_parser.rs` line-dispatch between `is_binding_line` / `absorb_adapter`
/ block-form `adapter "Name" do`) or in how `load_all_domains` mutates the
hecksagons map before `WebRegistry::scan`. Needs a runtime owner to trace.

Workaround (used by Deciderate): put the `:web` route in a SEPARATE binds-free
hecksagon (a route is a global HTTP surface, not tied to one domain). That
registers — but Gap 1 still 404s the template, so it doesn't actually serve.

## Net effect

Deciderate's admin DATA is two bluebook queries (`Decision.Joinable` +
`Decision.Decided`, committed) reachable at `GET
/domains/Deciderate/query/{joinable,decided}`. The admin PAGE (a thin client
that polls those + auto-refreshes) is written (`admin.html.template`) but cannot
be served by a hecksagon `:web` route until Gap 1 is fixed. Until then the admin
is the queries themselves (CLI: `storehouse query <dir>
Deciderate::Decision.joinable`), or a static client page served like index.html.
