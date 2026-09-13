# generated_entity_no_identity

Promoted from a `bin/qa_generated_domains` finding — generated, not
hand-written. The bluebook is the domain-shrunk minimal form of the
generated domain that surprised; `QaGenerated` was renamed to
`GeneratedEntityNoIdentity` and nothing else changed.

## Blueprint

```json
{
  "aggregates": [
    {
      "name": "Kiosk",
      "identity": [
        "code"
      ],
      "vos": {
        "KioskCode": {
          "kind": "string"
        },
        "LineSequence": {
          "kind": "positive"
        },
        "LineBatch": {
          "kind": "string"
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
      "lifecycle": null,
      "invariants": [

      ],
      "entities": [
        {
          "name": "Line",
          "identity": [
            "batch",
            "sequence"
          ],
          "requires": [

          ],
          "attributes": [
            {
              "name": "batch",
              "type": "LineBatch"
            },
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
            },
            {
              "name": "Settle",
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
                "LineSettled"
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
        }
      ],
      "queries": [

      ]
    }
  ],
  "policies": [

  ],
  "seed": 1005,
  "forms": [
    "composite_piece",
    "multi_emit"
  ]
}
```

## Finding

```json
{
  "seed": 1,
  "mode": "differential",
  "signature": [
    "refusals",
    "refusals:QaGenerated::Kiosk.Line.Settle"
  ],
  "steps": [
    {
      "verb": "QaGenerated::Kiosk.Open",
      "args": {
        "code": {
          "value": "juliet"
        },
        "with": null
      },
      "adversarial": [
        {
          "mutation": "routing_key",
          "bug": "BUG#7/#16/#8",
          "key": "with",
          "shape": "null",
          "declared": false
        }
      ]
    },
    {
      "verb": "QaGenerated::Kiosk.Line.Label",
      "args": {
        "label": {
          "value": "foxtrot"
        },
        "code": {
          "value": "juliet"
        },
        "id": "gen-9ddf0207"
      }
    },
    {
      "verb": "QaGenerated::Kiosk.Line.Settle",
      "args": {
        "code": {
          "value": "juliet"
        },
        "id": "gen-e94b068f"
      }
    },
    {
      "verb": "QaGenerated::Kiosk.Open",
      "args": {
        "code": {
          "value": "   "
        }
      },
      "adversarial": [
        {
          "mutation": "blank_identity",
          "bug": "BUG#15",
          "argument": "code",
          "shape": "whitespace"
        }
      ]
    },
    {
      "verb": "QaGenerated::Kiosk.Line.Label",
      "args": {
        "label": "india",
        "code": {
          "value": "juliet"
        },
        "id": "gen-1e422d19"
      }
    },
    {
      "verb": "QaGenerated::Kiosk.Open",
      "args": {
        "code": {
          "value": "delta echo"
        }
      }
    },
    {
      "verb": "QaGenerated::Kiosk.Line.Label",
      "args": {
        "label": null,
        "code": {
          "value": "juliet"
        },
        "id": "gen-d7350eca"
      },
      "adversarial": [
        {
          "mutation": "null_value_object",
          "bug": "BUG#14",
          "argument": "label",
          "value_object": "LineLabel",
          "closed_set": false,
          "shape": "null"
        }
      ]
    },
    {
      "verb": "QaGenerated::Kiosk.Open",
      "args": {
        "code": "hotel echo foxtrot"
      }
    },
    {
      "verb": "QaGenerated::Kiosk.Open",
      "args": {
        "code": [
          2,
          4
        ],
        "colour": "red"
      },
      "adversarial": [
        {
          "mutation": "refusal_precedence",
          "bug": "BUG#7/#8/#14",
          "mismatched": "code",
          "unknown": "colour",
          "shape": "mismatch+unknown"
        }
      ]
    },
    {
      "verb": "QaGenerated::Kiosk.Line.Settle",
      "args": {
        "code": {
          "value": "juliet"
        },
        "id": "gen-d5d1d423"
      }
    },
    {
      "verb": "QaGenerated::Kiosk.Line.Label",
      "args": {
        "label": {
          "value": "with, a comma"
        },
        "code": {
          "value": "gen-1432b1ce"
        },
        "id": "gen-1e5ea960"
      }
    },
    {
      "verb": "QaGenerated::Kiosk.Open",
      "args": {
        "code": {
          "value": "alpha charlie"
        }
      }
    },
    {
      "verb": "QaGenerated::Kiosk.Open",
      "args": {
        "code": {
          "value": "echo alpha bravo"
        }
      }
    },
    {
      "verb": "QaGenerated::Kiosk.Line.Settle",
      "args": {
        "code": {
          "value": "gen-dca675c9"
        },
        "id": null
      },
      "adversarial": [
        {
          "mutation": "routing_key",
          "bug": "BUG#7/#16/#8",
          "key": "id",
          "shape": "null",
          "declared": false
        }
      ]
    },
    {
      "verb": "QaGenerated::Kiosk.Line.Settle",
      "args": {
        "code": {
          "value": "hotel echo foxtrot"
        },
        "id": "gen-47e143e7"
      }
    },
    {
      "verb": "QaGenerated::Kiosk.Open",
      "args": {
        "code": "   "
      },
      "adversarial": [
        {
          "mutation": "blank_identity",
          "bug": "BUG#15",
          "argument": "code",
          "shape": "whitespace"
        }
      ]
    },
    {
      "verb": "QaGenerated::Kiosk.Open",
      "args": {
        "code": {
          "value": "alpha"
        }
      }
    },
    {
      "verb": "QaGenerated::Kiosk.Line.Label",
      "args": {
        "label": {
          "value": "x"
        },
        "code": {
          "value": "alpha"
        },
        "id": "gen-b8821c82"
      }
    },
    {
      "verb": "QaGenerated::Kiosk.Line.Label",
      "args": {
        "code": {
          "value": "gen-28ed8282"
        },
        "id": "gen-4db0073f",
        "with": "gen-28ed8282"
      },
      "adversarial": [
        {
          "mutation": "routing_key",
          "bug": "BUG#7/#16/#8",
          "key": "with",
          "shape": "scalar",
          "declared": false
        }
      ]
    },
    {
      "verb": "QaGenerated::Kiosk.Open",
      "args": {
        "code": {
          "value": "delta"
        }
      }
    },
    {
      "verb": "QaGenerated::Kiosk.Open",
      "args": {
        "code": {
          "value": "bravo charlie"
        }
      }
    },
    {
      "verb": "QaGenerated::Kiosk.Line.Label",
      "args": {
        "label": [
          3,
          10
        ],
        "code": {
          "value": "alpha charlie"
        },
        "id": "gen-18e86c12",
        "to": {
          "aggregate": "alpha charlie",
          "entities": [
            "gen-18e86c12"
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
      "verb": "QaGenerated::Kiosk.Open",
      "args": {
        "code": "with, a comma"
      }
    },
    {
      "verb": "QaGenerated::Kiosk.Open",
      "args": {
        "code": {
        }
      },
      "adversarial": [
        {
          "mutation": "null_value_object",
          "bug": "BUG#14",
          "argument": "code",
          "value_object": "KioskCode",
          "closed_set": false,
          "shape": "empty_object"
        }
      ]
    },
    {
      "verb": "QaGenerated::Kiosk.Open",
      "args": {
        "code": {
          "value": "hotel alpha"
        },
        "rank": "loud"
      }
    }
  ],
  "divergences": [
    {
      "field": "refusals",
      "ruby": [
        {
          "verb": "QaGenerated::Kiosk.Line.Label",
          "kind": "NotFound"
        },
        {
          "verb": "QaGenerated::Kiosk.Line.Settle",
          "kind": "NotFound"
        },
        {
          "verb": "QaGenerated::Kiosk.Open",
          "kind": "TypeMismatch"
        },
        {
          "verb": "QaGenerated::Kiosk.Line.Label",
          "kind": "NotFound"
        },
        {
          "verb": "QaGenerated::Kiosk.Line.Label",
          "kind": "TypeMismatch"
        },
        {
          "verb": "QaGenerated::Kiosk.Open",
          "kind": "UnknownArgument"
        },
        {
          "verb": "QaGenerated::Kiosk.Line.Settle",
          "kind": "NotFound"
        },
        {
          "verb": "QaGenerated::Kiosk.Line.Label",
          "kind": "NotFound"
        },
        {
          "verb": "QaGenerated::Kiosk.Line.Settle",
          "kind": "NotFound"
        },
        {
          "verb": "QaGenerated::Kiosk.Line.Settle",
          "kind": "NotFound"
        },
        {
          "verb": "QaGenerated::Kiosk.Open",
          "kind": "TypeMismatch"
        },
        {
          "verb": "QaGenerated::Kiosk.Line.Label",
          "kind": "NotFound"
        },
        {
          "verb": "QaGenerated::Kiosk.Line.Label",
          "kind": "TypeMismatch"
        },
        {
          "verb": "QaGenerated::Kiosk.Line.Label",
          "kind": "TypeMismatch"
        },
        {
          "verb": "QaGenerated::Kiosk.Open",
          "kind": "TypeMismatch"
        },
        {
          "verb": "QaGenerated::Kiosk.Open",
          "kind": "UnknownArgument"
        }
      ],
      "rust": [
        {
          "verb": "QaGenerated::Kiosk.Line.Label",
          "kind": "NotFound"
        },
        {
          "verb": "QaGenerated::Kiosk.Line.Settle",
          "kind": "NotFound"
        },
        {
          "verb": "QaGenerated::Kiosk.Open",
          "kind": "TypeMismatch"
        },
        {
          "verb": "QaGenerated::Kiosk.Line.Label",
          "kind": "NotFound"
        },
        {
          "verb": "QaGenerated::Kiosk.Line.Label",
          "kind": "TypeMismatch"
        },
        {
          "verb": "QaGenerated::Kiosk.Open",
          "kind": "UnknownArgument"
        },
        {
          "verb": "QaGenerated::Kiosk.Line.Settle",
          "kind": "NotFound"
        },
        {
          "verb": "QaGenerated::Kiosk.Line.Label",
          "kind": "NotFound"
        },
        {
          "verb": "QaGenerated::Kiosk.Line.Settle",
          "kind": "TypeMismatch"
        },
        {
          "verb": "QaGenerated::Kiosk.Line.Settle",
          "kind": "NotFound"
        },
        {
          "verb": "QaGenerated::Kiosk.Open",
          "kind": "TypeMismatch"
        },
        {
          "verb": "QaGenerated::Kiosk.Line.Label",
          "kind": "NotFound"
        },
        {
          "verb": "QaGenerated::Kiosk.Line.Label",
          "kind": "TypeMismatch"
        },
        {
          "verb": "QaGenerated::Kiosk.Line.Label",
          "kind": "TypeMismatch"
        },
        {
          "verb": "QaGenerated::Kiosk.Open",
          "kind": "TypeMismatch"
        },
        {
          "verb": "QaGenerated::Kiosk.Open",
          "kind": "UnknownArgument"
        }
      ]
    }
  ],
  "shrunk_steps": [
    {
      "verb": "QaGenerated::Kiosk.Line.Settle",
      "args": {
      },
      "adversarial": [
        {
          "mutation": "routing_key",
          "bug": "BUG#7/#16/#8",
          "key": "id",
          "shape": "null",
          "declared": false
        }
      ]
    }
  ],
  "status": "found",
  "seeds_run": 1
}
```
