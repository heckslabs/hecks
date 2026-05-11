# integration/

External systems the framework talks to.

| Adapter | What |
|---|---|
| `cloudflare_deploy/` | **(not copied — source bluebooks flag primitive-envy validator errors)** ; originals at `../../integrations/cloudflare_deploy/` — now split into `cloudflare_artifacts.bluebook` (codegen) + `cloudflare_deploy.bluebook` (runtime push) ; 62-unit structural warning resolved (i532). |
| `slack/` | Ruby Slack webhook adapter for notifications. Pre-bluebook. |

`miette_phone.bluebook` (at `../../integrations/cloudflare_deploy/`) is a deployment **instance** rather than an adapter — left in place ; surfaced here for Chris to decide whether it belongs in `adapters/` at all.
