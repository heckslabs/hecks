# serving/

Driving adapters — the surfaces that call **into** the bus from the outside world.

| Adapter | What |
|---|---|
| `bubble/` | "Bubble" surface — aggregate mapper + context for Bubble.io-style external front-ends. |
| `docs/` | README + docs writer ; surfaces domain reference from bluebook. |
| `serve/` | The HTTP server — domain server, multi-domain server, RPC server, route builder. |
| `web_application_creation/` | **(not copied — source bluebook flags validator errors)** ; original at `../../integrations/web_application_creation/`. |
| `web_components/` | **(not copied — source bluebook flags 7 validator errors)** ; original at `../../integrations/web_components/`. |
| `web_explorer/` | Live IR + events introspector served as web pages. |
