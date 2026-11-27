# generated_route_append

Promoted from a `bin/qa_generated_domains` finding — generated, not
hand-written. The bluebook is the domain-shrunk minimal form of the
generated domain that surprised; `QaGenerated` was renamed to
`GeneratedRouteAppend` and nothing else changed.

## Blueprint

```json
{
  "aggregates": [
    {
      "name": "Hangar",
      "identity": [
        "code"
      ],
      "vos": {
        "HangarCode": {
          "kind": "string"
        },
        "HangarTag": {
          "kind": "string"
        },
        "HangarPriority": {
          "kind": "closed",
          "members": [
            "red",
            "amber",
            "green"
          ]
        },
        "HangarScore": {
          "kind": "integer"
        }
      },
      "attributes": [
        {
          "name": "code",
          "type": "HangarCode"
        }
      ],
      "references": [

      ],
      "lifecycle": null,
      "invariants": [

      ],
      "entities": [

      ],
      "commands": [
        {
          "name": "Open",
          "creates": true,
          "references": [

          ],
          "args": [
            {
              "name": "code",
              "type": "HangarCode"
            }
          ],
          "givens": [

          ],
          "sets": [
            {
              "target": "code"
            }
          ],
          "emits": [
            "HangarOpened"
          ]
        },
        {
          "name": "Retag",
          "creates": false,
          "references": [

          ],
          "args": [
            {
              "name": "tags",
              "type": "HangarTag",
              "list": true
            }
          ],
          "givens": [

          ],
          "sets": [

          ],
          "emits": [
            "HangarRetaged"
          ]
        },
        {
          "name": "Prioritize",
          "creates": false,
          "references": [

          ],
          "args": [
            {
              "name": "priority",
              "type": "HangarPriority"
            }
          ],
          "givens": [

          ],
          "sets": [

          ],
          "emits": [
            "HangarPrioritized"
          ]
        },
        {
          "name": "Rescore",
          "creates": false,
          "references": [

          ],
          "args": [
            {
              "name": "amount",
              "type": "HangarScore"
            }
          ],
          "givens": [

          ],
          "sets": [

          ],
          "emits": [
            "HangarRescored"
          ]
        }
      ],
      "queries": [

      ]
    },
    {
      "name": "Kiosk",
      "identity": [
        "code"
      ],
      "vos": {
        "KioskCode": {
          "kind": "string"
        },
        "KioskPriority": {
          "kind": "closed",
          "members": [
            "low",
            "high"
          ]
        },
        "KioskScore": {
          "kind": "integer"
        },
        "LineSequence": {
          "kind": "positive"
        },
        "LineLabel": {
          "kind": "string"
        }
      },
      "attributes": [
        {
          "name": "code",
          "type": "KioskCode"
        },
        {
          "name": "lines",
          "type": "Line",
          "list": true,
          "requires": [
            "entity:Kiosk.Line"
          ]
        }
      ],
      "references": [

      ],
      "lifecycle": {
        "field": "status",
        "default": "open",
        "transitions": [
          {
            "command": "Close",
            "to": "closed",
            "from": [
              "open"
            ],
            "requires": [
              "command:Kiosk.Close"
            ]
          },
          {
            "command": "Reopen",
            "to": "open",
            "from": [
              "closed"
            ],
            "requires": [
              "command:Kiosk.Reopen"
            ]
          }
        ]
      },
      "invariants": [

      ],
      "entities": [
        {
          "name": "Line",
          "identity": [
            "sequence"
          ],
          "requires": [

          ],
          "attributes": [
            {
              "name": "sequence",
              "type": "LineSequence"
            },
            {
              "name": "label",
              "type": "LineLabel",
              "optional": true
            }
          ],
          "lifecycle": null,
          "commands": [
            {
              "name": "Label",
              "creates": false,
              "references": [

              ],
              "args": [
                {
                  "name": "label",
                  "type": "LineLabel"
                }
              ],
              "givens": [

              ],
              "sets": [
                {
                  "target": "label"
                }
              ],
              "emits": [
                "LineLabeled"
              ]
            }
          ]
        }
      ],
      "commands": [
        {
          "name": "Open",
          "creates": true,
          "references": [

          ],
          "args": [
            {
              "name": "code",
              "type": "KioskCode"
            }
          ],
          "givens": [

          ],
          "sets": [
            {
              "target": "code"
            }
          ],
          "emits": [
            "KioskOpened"
          ]
        },
        {
          "name": "Close",
          "creates": false,
          "references": [

          ],
          "args": [

          ],
          "givens": [

          ],
          "sets": [

          ],
          "emits": [
            "KioskClosed"
          ]
        },
        {
          "name": "Reopen",
          "creates": false,
          "references": [

          ],
          "args": [

          ],
          "givens": [

          ],
          "sets": [

          ],
          "emits": [
            "KioskReopened"
          ]
        },
        {
          "name": "Prioritize",
          "creates": false,
          "references": [

          ],
          "args": [
            {
              "name": "priority",
              "type": "KioskPriority"
            }
          ],
          "givens": [

          ],
          "sets": [

          ],
          "emits": [
            "KioskPrioritized"
          ],
          "role": "Clerk"
        },
        {
          "name": "Rescore",
          "creates": false,
          "references": [

          ],
          "args": [
            {
              "name": "amount",
              "type": "KioskScore"
            }
          ],
          "givens": [

          ],
          "sets": [

          ],
          "emits": [
            "KioskRescored"
          ],
          "role": "Manager"
        },
        {
          "name": "AddLine",
          "creates": false,
          "references": [

          ],
          "args": [
            {
              "name": "sequence",
              "type": "LineSequence"
            }
          ],
          "givens": [

          ],
          "sets": [
            {
              "target": "lines",
              "append": {
                "sequence": "sequence"
              },
              "requires": [
                "attribute:Kiosk.lines",
                "entity:Kiosk.Line"
              ]
            }
          ],
          "emits": [
            "LineAdded"
          ],
          "role": "Manager"
        }
      ],
      "queries": [
        {
          "name": "Listed",
          "wheres": [
            {
              "field": "status",
              "value": "open",
              "requires": [
                "lifecycle:Kiosk"
              ]
            }
          ],
          "order_by": "code"
        }
      ]
    }
  ],
  "policies": [

  ],
  "seed": 1013,
  "forms": [
    "list_attr",
    "multi_emit"
  ]
}
```

## Finding

```json
{
  "seed": 4,
  "mode": "differential",
  "signature": [
    "refusals",
    "refusals:QaGenerated::Kiosk.AddLine"
  ],
  "steps": [
    {
      "verb": "QaGenerated::Kiosk.Open",
      "args": {
        "code": null
      },
      "adversarial": [
        {
          "mutation": "blank_identity",
          "bug": "BUG#15",
          "argument": "code",
          "shape": "null"
        }
      ]
    },
    {
      "query": "QaGenerated::Kiosk.Listed",
      "args": {
      }
    },
    {
      "verb": "QaGenerated::Kiosk.Open",
      "args": {
        "code": null
      },
      "adversarial": [
        {
          "mutation": "null_value_object",
          "bug": "BUG#14",
          "argument": "code",
          "value_object": "KioskCode",
          "closed_set": false,
          "shape": "null"
        }
      ]
    },
    {
      "verb": "QaGenerated::Hangar.Open",
      "args": {
        "code": "india bravo charlie"
      }
    },
    {
      "verb": "QaGenerated::Hangar.Rescore",
      "args": {
        "amount": -1267650600228229401496703205376,
        "code": {
          "value": "india bravo charlie"
        }
      }
    },
    {
      "verb": "QaGenerated::Hangar.Prioritize",
      "args": {
        "priority": "red",
        "code": {
          "value": "india bravo charlie"
        }
      }
    },
    {
      "verb": "QaGenerated::Kiosk.Open",
      "args": {
        "code": {
          "value": "hotel india charlie"
        }
      }
    },
    {
      "verb": "QaGenerated::Kiosk.Rescore",
      "args": {
        "amount": {
          "value": [
            "nested",
            "array"
          ]
        },
        "code": {
          "value": "hotel india charlie"
        }
      }
    },
    {
      "verb": "QaGenerated::Hangar.Retag",
      "args": {
        "tags": [
          {
            "value": "echo"
          },
          {
            "value": "foxtrot echo"
          }
        ],
        "code": {
          "value": "india bravo charlie"
        }
      }
    },
    {
      "verb": "QaGenerated::Kiosk.AddLine",
      "args": {
        "sequence": {
          "value": -1267650600228229401496703205376
        },
        "code": {
          "value": "hotel india charlie"
        }
      }
    },
    {
      "verb": "QaGenerated::Hangar.Open",
      "args": {
        "code": {
          "value": [
            "nested",
            "array"
          ]
        },
        "note": "red"
      },
      "adversarial": [
        {
          "mutation": "refusal_precedence",
          "bug": "BUG#7/#8/#14",
          "mismatched": "code",
          "unknown": "note",
          "shape": "mismatch+unknown"
        }
      ]
    },
    {
      "verb": "QaGenerated::Kiosk.Prioritize",
      "args": {
        "priority": {
          "value": "low"
        },
        "code": {
          "value": "hotel india charlie"
        }
      }
    },
    {
      "verb": "QaGenerated::Hangar.Rescore",
      "args": {
        "amount": 900,
        "code": {
          "value": "india bravo charlie"
        }
      }
    },
    {
      "verb": "QaGenerated::Kiosk.Rescore",
      "args": {
        "amount": null,
        "code": {
          "value": "hotel india charlie"
        }
      },
      "adversarial": [
        {
          "mutation": "null_value_object",
          "bug": "BUG#14",
          "argument": "amount",
          "value_object": "KioskScore",
          "closed_set": false,
          "shape": "null"
        }
      ]
    },
    {
      "verb": "QaGenerated::Hangar.Open",
      "args": {
        "code": {
          "value": "alpha juliet"
        }
      }
    },
    {
      "verb": "QaGenerated::Kiosk.Reopen",
      "args": {
        "code": {
          "value": "hotel india charlie"
        }
      }
    },
    {
      "verb": "QaGenerated::Hangar.Prioritize",
      "args": {
        "priority": {
          "value": "green"
        },
        "code": {
          "value": "india bravo charlie"
        }
      }
    },
    {
      "verb": "QaGenerated::Kiosk.AddLine",
      "args": {
        "code": {
          "value": "gen-04169a15"
        },
        "to": {
          "aggregate": "gen-04169a15",
          "entities": [
            "gen-1a34ac08"
          ]
        }
      },
      "adversarial": [
        {
          "mutation": "routing_key",
          "bug": "BUG#7/#16/#8",
          "key": "to",
          "shape": "route",
          "declared": false
        }
      ]
    },
    {
      "verb": "QaGenerated::Kiosk.Close",
      "args": {
        "code": {
          "value": "hotel india charlie"
        }
      }
    },
    {
      "verb": "QaGenerated::Hangar.Rescore",
      "args": {
        "amount": null,
        "code": {
          "value": "india bravo charlie"
        }
      },
      "adversarial": [
        {
          "mutation": "null_value_object",
          "bug": "BUG#14",
          "argument": "amount",
          "value_object": "HangarScore",
          "closed_set": false,
          "shape": "null"
        }
      ]
    },
    {
      "verb": "QaGenerated::Kiosk.Line.Label",
      "args": {
        "label": {
          "value": "foxtrot juliet juliet"
        },
        "code": {
          "value": "gen-eb16c4ba"
        },
        "sequence": {
          "value": 0
        }
      }
    },
    {
      "verb": "QaGenerated::Hangar.Prioritize",
      "args": {
        "priority": {
          "value": "  leading and trailing  "
        },
        "code": {
          "value": "gen-976d1b3a"
        }
      }
    },
    {
      "verb": "QaGenerated::Kiosk.Reopen",
      "args": {
        "code": {
          "value": "hotel india charlie"
        }
      }
    },
    {
      "verb": "QaGenerated::Kiosk.Line.Label",
      "args": {
        "label": {
          "value": "delta"
        },
        "code": {
          "value": "hotel india charlie"
        },
        "sequence": {
          "value": 0
        }
      }
    },
    {
      "verb": "QaGenerated::Hangar.Open",
      "args": {
        "code": {
          "value": "charlie alpha"
        }
      }
    }
  ],
  "divergences": [
    {
      "field": "refusals",
      "ruby": [
        {
          "verb": "QaGenerated::Kiosk.Open",
          "kind": "TypeMismatch"
        },
        {
          "verb": "QaGenerated::Kiosk.Open",
          "kind": "TypeMismatch"
        },
        {
          "verb": "QaGenerated::Hangar.Rescore",
          "kind": "TypeMismatch"
        },
        {
          "verb": "QaGenerated::Kiosk.Rescore",
          "kind": "TypeMismatch"
        },
        {
          "verb": "QaGenerated::Kiosk.AddLine",
          "kind": "TypeMismatch"
        },
        {
          "verb": "QaGenerated::Hangar.Open",
          "kind": "UnknownArgument"
        },
        {
          "verb": "QaGenerated::Kiosk.Rescore",
          "kind": "TypeMismatch"
        },
        {
          "verb": "QaGenerated::Kiosk.Reopen",
          "kind": "LifecycleRefused"
        },
        {
          "verb": "QaGenerated::Kiosk.AddLine",
          "kind": "TypeMismatch"
        },
        {
          "verb": "QaGenerated::Hangar.Rescore",
          "kind": "TypeMismatch"
        },
        {
          "verb": "QaGenerated::Kiosk.Line.Label",
          "kind": "NotFound"
        },
        {
          "verb": "QaGenerated::Hangar.Prioritize",
          "kind": "InvariantViolation"
        },
        {
          "verb": "QaGenerated::Kiosk.Line.Label",
          "kind": "NotFound"
        }
      ],
      "rust": [
        {
          "verb": "QaGenerated::Kiosk.Open",
          "kind": "TypeMismatch"
        },
        {
          "verb": "QaGenerated::Kiosk.Open",
          "kind": "TypeMismatch"
        },
        {
          "verb": "QaGenerated::Hangar.Rescore",
          "kind": "TypeMismatch"
        },
        {
          "verb": "QaGenerated::Kiosk.Rescore",
          "kind": "TypeMismatch"
        },
        {
          "verb": "QaGenerated::Kiosk.AddLine",
          "kind": "TypeMismatch"
        },
        {
          "verb": "QaGenerated::Hangar.Open",
          "kind": "UnknownArgument"
        },
        {
          "verb": "QaGenerated::Kiosk.Rescore",
          "kind": "TypeMismatch"
        },
        {
          "verb": "QaGenerated::Kiosk.Reopen",
          "kind": "LifecycleRefused"
        },
        {
          "verb": "QaGenerated::Kiosk.AddLine",
          "kind": "AbsentArgument"
        },
        {
          "verb": "QaGenerated::Hangar.Rescore",
          "kind": "TypeMismatch"
        },
        {
          "verb": "QaGenerated::Kiosk.Line.Label",
          "kind": "NotFound"
        },
        {
          "verb": "QaGenerated::Hangar.Prioritize",
          "kind": "InvariantViolation"
        },
        {
          "verb": "QaGenerated::Kiosk.Line.Label",
          "kind": "NotFound"
        }
      ]
    }
  ],
  "shrunk_steps": [
    {
      "verb": "QaGenerated::Kiosk.AddLine",
      "args": {
        "to": {
          "aggregate": "gen-04169a15",
          "entities": [
            "gen-1a34ac08"
          ]
        }
      },
      "adversarial": [
        {
          "mutation": "routing_key",
          "bug": "BUG#7/#16/#8",
          "key": "to",
          "shape": "route",
          "declared": false
        }
      ]
    }
  ],
  "status": "found",
  "seeds_run": 4
}
```

## BUG#129 — dry run of an undeclared `with:` fact

`GeneratedRouteAppend::Hangar.Open` called as a `dry_run` with `{code:
"india", with: null}` answered `ok: false` in Ruby and `ok: true` in
Rust — the BUG#16/#17 routing-key family (`to`/`with` reserved as the
routing envelope's own keys, sniffed even when the caller means them as
a flat, undeclared command fact), reached this time through the
`dry_run` door rather than a real dispatch. Found by `bin/qa_sweep
SW-generated_route_append-1789342558`, shrunk to 1 step
(`repro_dry_run.json`, committed alongside BUG#128's own repro by #636).

Investigated 2026-09-18: already fixed, no Ruby or Rust change needed.
BUG#131 (commit `8a572881`, PR #639) gave `dry_run()`'s two call sites
(`rust/src/kernel/cli.rs`) a dedicated `dry_run_command_input()` that
wraps EVERY dry run's args as `{"with": args}` unconditionally — so
`CommandInvocation::from_json` never again inspects a dry run's own flat
facts for a `to`/`with` key at all, regardless of which reserved key a
domain's own undeclared fact happens to collide with. That fix was
written against `examples/roster`'s `to` collision
(`roster_mark_dry_run_to_collision.json`); this bug's own `with`
collision is the identical mechanism, one key over, and is closed by the
same code — dry_run's own check now runs the same "undeclared argument"
validation real dispatch already did.

The two bugs' filing order was a race, not a sequencing bug: BUG#131
merged at 2026-09-14 00:25:59 UTC; this bug was logged ~42 minutes later
at 01:07:45 UTC by a sweep whose own branch was evidently cut before
BUG#131 landed, so `bin/qa_log_bug`'s own demonstration check genuinely
failed at the moment it ran — `git merge-base --is-ancestor 8a572881
40bb41fb` confirms BUG#131's fix was already an ancestor of the commit
that logged this bug by the time it merged into main, even though the
demonstration wasn't re-run against that state before filing. Re-run
today:

```
$ bundle exec ruby bin/rust_conformance qa/stress_domains/generated_route_append \
    qa/stress_domains/generated_route_append/repro_dry_run.json build
qa/stress_domains/generated_route_append / qa/stress_domains/generated_route_append/repro_dry_run.json: matches.
```
