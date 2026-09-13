# generated_reaction_wording

Promoted from a `bin/qa_generated_domains` finding — generated, not
hand-written. The bluebook is the domain-shrunk minimal form of the
generated domain that surprised; `QaGenerated` was renamed to
`GeneratedReactionWording` and nothing else changed.

## Blueprint

```json
{
  "aggregates": [
    {
      "name": "Desk",
      "identity": [
        "code"
      ],
      "vos": {
        "DeskCode": {
          "kind": "string"
        },
        "LineSequence": {
          "kind": "positive"
        },
        "LineLabel": {
          "kind": "string"
        },
        "DeskScore": {
          "kind": "integer"
        }
      },
      "attributes": [
        {
          "name": "code",
          "type": "DeskCode"
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
              "command:Desk.Close"
            ]
          }
        ]
      },
      "invariants": [

      ],
      "entities": [

      ],
      "commands": [
        {
          "name": "Open",
          "creates": true,
          "references": [
            "Parcel"
          ],
          "args": [
            {
              "name": "code",
              "type": "DeskCode"
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
            "DeskOpened"
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
            "DeskClosed"
          ]
        }
      ],
      "queries": [

      ]
    },
    {
      "name": "Parcel",
      "identity": [
        "code"
      ],
      "vos": {
        "ParcelCode": {
          "kind": "string"
        },
        "ParcelPriority": {
          "kind": "closed",
          "members": [
            "draft",
            "final"
          ]
        },
        "ParcelNote": {
          "kind": "string"
        }
      },
      "attributes": [
        {
          "name": "code",
          "type": "ParcelCode"
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
              "type": "ParcelCode"
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
            "ParcelOpened"
          ]
        },
        {
          "name": "Annotate",
          "creates": false,
          "references": [

          ],
          "args": [
            {
              "name": "note",
              "type": "ParcelNote",
              "optional": true
            }
          ],
          "givens": [

          ],
          "sets": [

          ],
          "emits": [
            "ParcelAnnotated"
          ]
        }
      ],
      "queries": [

      ]
    }
  ],
  "policies": [
    {
      "name": "OnDeskOpenedClose",
      "on": "Desk::DeskOpened",
      "trigger": "Desk::Close",
      "requires": [
        "event:Desk.DeskOpened",
        "command:Desk.Close",
        "lifecycle:Desk"
      ]
    }
  ],
  "seed": 1002,
  "forms": [
    "has_query",
    "has_entity"
  ]
}
```

## Finding

```json
{
  "seed": 1,
  "mode": "differential",
  "signature": [
    "reactions",
    "reactions:OnDeskOpenedClose"
  ],
  "steps": [
    {
      "verb": "QaGenerated::Parcel.Open",
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
      "verb": "QaGenerated::Desk.Open",
      "args": {
        "parcel": "juliet",
        "code": null
      },
      "adversarial": [
        {
          "mutation": "null_value_object",
          "bug": "BUG#14",
          "argument": "code",
          "value_object": "DeskCode",
          "closed_set": false,
          "shape": "null"
        }
      ]
    },
    {
      "verb": "QaGenerated::Parcel.Annotate",
      "args": {
        "code": {
          "value": "juliet"
        }
      }
    },
    {
      "verb": "QaGenerated::Desk.Open",
      "args": {
        "code": {
        }
      },
      "adversarial": [
        {
          "mutation": "null_value_object",
          "bug": "BUG#14",
          "argument": "code",
          "value_object": "DeskCode",
          "closed_set": false,
          "shape": "empty_object"
        }
      ]
    },
    {
      "verb": "QaGenerated::Parcel.Annotate",
      "args": {
        "code": {
          "value": "juliet"
        }
      }
    },
    {
      "verb": "QaGenerated::Desk.Open",
      "args": {
        "parcel": "missing-182b254a",
        "code": {
          "value": "echo"
        },
        "note": "red"
      }
    },
    {
      "verb": "QaGenerated::Desk.Open",
      "args": {
        "parcel": "juliet",
        "code": null,
        "note": "loud"
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
      "verb": "QaGenerated::Parcel.Annotate",
      "args": {
        "note": {
          "value": "hotel delta"
        },
        "code": {
          "value": "juliet"
        }
      }
    },
    {
      "verb": "QaGenerated::Desk.Open",
      "args": {
        "parcel": "juliet",
        "code": {
          "value": "golf"
        }
      }
    },
    {
      "verb": "QaGenerated::Parcel.Open",
      "args": {
        "code": {
          "value": "india echo"
        }
      }
    },
    {
      "verb": "QaGenerated::Desk.Close",
      "args": {
        "code": {
          "value": "golf"
        }
      }
    },
    {
      "verb": "QaGenerated::Parcel.Open",
      "args": {
        "code": {
          "value": "with a \\backslash"
        }
      }
    },
    {
      "verb": "QaGenerated::Parcel.Open",
      "args": {
        "code": null,
        "rank": "third"
      },
      "adversarial": [
        {
          "mutation": "refusal_precedence",
          "bug": "BUG#7/#8/#14",
          "mismatched": "code",
          "unknown": "rank",
          "shape": "mismatch+unknown"
        }
      ]
    },
    {
      "verb": "QaGenerated::Desk.Close",
      "args": {
        "code": {
          "value": "golf"
        }
      }
    },
    {
      "verb": "QaGenerated::Desk.Open",
      "args": {
        "code": {
          "value": "bravo echo"
        }
      }
    },
    {
      "verb": "QaGenerated::Parcel.Annotate",
      "args": {
        "code": {
          "value": "india echo"
        }
      }
    },
    {
      "verb": "QaGenerated::Desk.Open",
      "args": {
        "parcel": "juliet",
        "code": {
          "value": "juliet"
        }
      }
    },
    {
      "verb": "QaGenerated::Desk.Close",
      "args": {
        "code": {
          "value": "gen-a8bd858d"
        },
        "note": "loud"
      },
      "adversarial": [
        {
          "mutation": "refusal_precedence",
          "bug": "BUG#7/#8/#14",
          "unknown": "note",
          "nonexistent": "code",
          "shape": "nonexistent+unknown"
        }
      ]
    },
    {
      "verb": "QaGenerated::Parcel.Open",
      "args": {
        "code": {
          "value": "delta"
        }
      }
    },
    {
      "verb": "QaGenerated::Desk.Open",
      "args": {
        "parcel": "india echo",
        "code": {
          "value": "delta"
        }
      }
    },
    {
      "verb": "QaGenerated::Desk.Open",
      "args": {
        "parcel": "with a \\backslash",
        "code": {
          "value": "unicode héllo wörld 🎉"
        }
      }
    },
    {
      "verb": "QaGenerated::Parcel.Annotate",
      "args": {
        "note": "scribbled",
        "code": {
          "value": "gen-35fccd0c"
        }
      },
      "adversarial": [
        {
          "mutation": "refusal_precedence",
          "bug": "BUG#7/#8/#14",
          "unknown": "note",
          "nonexistent": "code",
          "shape": "nonexistent+unknown"
        }
      ]
    },
    {
      "verb": "QaGenerated::Parcel.Open",
      "args": {
        "code": {
          "value": "echo"
        }
      }
    },
    {
      "verb": "QaGenerated::Parcel.Open",
      "args": {
        "code": {
          "value": "hotel alpha"
        },
        "rank": "loud"
      }
    },
    {
      "verb": "QaGenerated::Parcel.Open",
      "args": {
        "code": "hotel delta"
      }
    }
  ],
  "divergences": [
    {
      "field": "reactions",
      "ruby": [
        {
          "policy": "OnDeskOpenedClose",
          "on": "DeskOpened",
          "trigger": "QaGenerated::Desk.Close",
          "delivered": false,
          "reason": "Close does not declare parcel — it takes none"
        },
        {
          "policy": "OnDeskOpenedClose",
          "on": "DeskOpened",
          "trigger": "QaGenerated::Desk.Close",
          "delivered": false,
          "reason": "Close does not declare parcel — it takes none"
        },
        {
          "policy": "OnDeskOpenedClose",
          "on": "DeskOpened",
          "trigger": "QaGenerated::Desk.Close",
          "delivered": false,
          "reason": "Close does not declare parcel — it takes none"
        },
        {
          "policy": "OnDeskOpenedClose",
          "on": "DeskOpened",
          "trigger": "QaGenerated::Desk.Close",
          "delivered": false,
          "reason": "Close does not declare parcel — it takes none"
        }
      ],
      "rust": [
        {
          "policy": "OnDeskOpenedClose",
          "on": "DeskOpened",
          "trigger": "QaGenerated::Desk.Close",
          "delivered": false,
          "reason": "Close does not declare parcel — it takes "
        },
        {
          "policy": "OnDeskOpenedClose",
          "on": "DeskOpened",
          "trigger": "QaGenerated::Desk.Close",
          "delivered": false,
          "reason": "Close does not declare parcel — it takes "
        },
        {
          "policy": "OnDeskOpenedClose",
          "on": "DeskOpened",
          "trigger": "QaGenerated::Desk.Close",
          "delivered": false,
          "reason": "Close does not declare parcel — it takes "
        },
        {
          "policy": "OnDeskOpenedClose",
          "on": "DeskOpened",
          "trigger": "QaGenerated::Desk.Close",
          "delivered": false,
          "reason": "Close does not declare parcel — it takes "
        }
      ]
    }
  ],
  "shrunk_steps": [
    {
      "verb": "QaGenerated::Parcel.Open",
      "args": {
        "code": {
          "value": "juliet"
        }
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
      "verb": "QaGenerated::Desk.Open",
      "args": {
        "parcel": "juliet",
        "code": {
          "value": "golf"
        }
      }
    }
  ],
  "status": "found",
  "seeds_run": 1
}
```
