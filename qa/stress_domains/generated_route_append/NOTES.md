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
