# composite_line_ledger

Promoted from a `bin/qa_generated_domains` finding — generated, not
hand-written. The bluebook is the minimal form of the domain that
surprised; `QaGenerated` was renamed to `CompositeLineLedger` and nothing
else changed.

**Kept despite `bin/qa_domain_novelty` reporting no new form pair.** That
gate measures one aggregate's own declared forms; this domain's point is
a codegen construct invisible to it, the same way `corrects` and
`role_gated` were before those got named. The construct: **duplicate-identity
enforcement on an `append:` mutation, when the target entity's
`identified_by` is composite** (`Venue::Line identified_by :batch,
:sequence`). Both Rust codegens (`rust/project/mutations.rb`, the
Ruby-primary one per ADR 0054b, and its Rust-ported twin
`rust/codegen/src/mutations.rs`) had a `collision_guard` for a
caller-supplied entity identity on `append:` that was gated on
`identified_by.size == 1` — a composite identity got no guard AT ALL, not
even a partial/wrong one. `Venue.AddLine` dispatched twice with the same
`(batch, sequence)` silently double-appended in Rust (two `VenueLineAdded`
events, `#{lines}` holding the same tuple twice) while Ruby's
`EntityElement.check_entity_collision` (which already compares every
`identified_by` head at once, `heads.all?`) correctly refused the second
call with `AlreadyExists`. Found by this domain's first real differential
sweep, shrunk to 3 steps (`Open`, `AddLine`, `AddLine` again with the same
`batch`+`sequence`). Logged as BUG#<see NOTES below for the exact number
at fix time — check the ledger> and fixed by generalizing the single-head
guard in both codegens (and the sibling whole-list-replace guard,
`entity_list_replace_guard`, which had the identical `size == 1`
exclusion) to compare every identity head at once, mirroring Ruby's
`heads.all?` exactly. This is the composite-identity twin of BUG#13/BUG#145
(single-field identity duplicates), which is exactly why the generator's
`duplicate_entity_identity` adversarial mutation already tags composite
attempts (`"composite" => true`) — nothing had exercised that tag against
an aggregate-owned composite-identity `list_of` before this domain did.

## Blueprint

```json
{
  "aggregates": [
    {
      "name": "Venue",
      "identity": [
        "code"
      ],
      "vos": {
        "VenueCode": {
          "kind": "string"
        },
        "VenueScore": {
          "kind": "integer"
        },
        "LineSequence": {
          "kind": "positive"
        },
        "LineBatch": {
          "kind": "string"
        },
        "LineLabel": {
          "kind": "string"
        },
        "VenuePriority": {
          "kind": "closed",
          "members": [
            "red",
            "amber",
            "green"
          ]
        }
      },
      "attributes": [
        {
          "name": "code",
          "type": "VenueCode"
        },
        {
          "name": "lines",
          "type": "Line",
          "list": true,
          "requires": [
            "entity:Venue.Line"
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
                "VenueLineLabeled"
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
              "type": "VenueCode"
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
            "VenueOpened"
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
              "type": "VenueScore"
            }
          ],
          "givens": [

          ],
          "sets": [

          ],
          "emits": [
            "VenueRescored"
          ]
        },
        {
          "name": "AddLine",
          "creates": false,
          "references": [

          ],
          "args": [
            {
              "name": "batch",
              "type": "LineBatch"
            },
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
                "batch": "batch",
                "sequence": "sequence"
              },
              "requires": [
                "attribute:Venue.lines",
                "entity:Venue.Line"
              ]
            }
          ],
          "emits": [
            "VenueLineAdded"
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
              "type": "VenuePriority"
            }
          ],
          "givens": [

          ],
          "sets": [

          ],
          "emits": [
            "VenuePrioritized"
          ]
        }
      ],
      "queries": [

      ]
    },
    {
      "name": "Hangar",
      "identity": [
        "code"
      ],
      "vos": {
        "HangarCode": {
          "kind": "string"
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
            "HangarReopened"
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
          ],
          "role": "Manager"
        }
      ],
      "queries": [

      ]
    }
  ],
  "policies": [

  ],
  "seed": 556518,
  "forms": [
    "has_default",
    "composite_piece"
  ]
}
```

## Finding

```json
{
  "seed": 4,
  "mode": "differential",
  "signature": [
    "events",
    "instances",
    "instances:QaGenerated::Venue",
    "refusals",
    "refusals:QaGenerated::Venue.AddLine"
  ],
  "steps": [
    {
      "verb": "QaGenerated::Hangar.Open",
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
      "verb": "QaGenerated::Venue.Open",
      "args": {
        "code": {
          "value": "echo"
        }
      }
    },
    {
      "verb": "QaGenerated::Venue.Line.Label",
      "args": {
        "label": "foxtrot juliet",
        "code": {
          "value": "gen-7535e7f4"
        },
        "id": "gen-1ec4a1cf"
      }
    },
    {
      "verb": "QaGenerated::Venue.Prioritize",
      "args": {
        "priority": {
          "value": "bravo alpha delta"
        },
        "code": {
          "value": "echo"
        }
      }
    },
    {
      "verb": "QaGenerated::Venue.AddLine",
      "args": {
        "batch": "bravo",
        "sequence": {
          "value": 461
        },
        "code": {
          "value": "echo"
        }
      }
    },
    {
      "verb": "QaGenerated::Hangar.Open",
      "args": {
        "code": {
          "value": "hotel hotel juliet"
        }
      }
    },
    {
      "verb": "QaGenerated::Hangar.Rescore",
      "args": {
        "amount": null,
        "code": {
          "value": "hotel hotel juliet"
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
      "verb": "QaGenerated::Venue.Open",
      "args": {
        "code": {
          "value": "golf"
        }
      }
    },
    {
      "verb": "QaGenerated::Venue.Rescore",
      "args": {
        "amount": {
          "value": 566
        },
        "code": {
          "value": "golf"
        }
      }
    },
    {
      "verb": "QaGenerated::Hangar.Open",
      "args": {
        "code": {
          "value": "with, a comma"
        }
      }
    },
    {
      "verb": "QaGenerated::Venue.AddLine",
      "args": {
        "batch": "with a \\backslash",
        "sequence": {
          "value": 654
        },
        "code": {
          "value": "golf"
        },
        "to": null
      },
      "adversarial": [
        {
          "mutation": "routing_key",
          "bug": "BUG#7/#16/#8",
          "key": "to",
          "shape": "null",
          "declared": false
        }
      ]
    },
    {
      "verb": "QaGenerated::Venue.Rescore",
      "args": {
        "amount": {
          "value": 610
        },
        "code": {
          "value": "echo"
        }
      }
    },
    {
      "verb": "QaGenerated::Venue.AddLine",
      "args": {
        "batch": "with a \\backslash",
        "sequence": {
          "value": 654
        },
        "code": {
          "value": "golf"
        }
      },
      "adversarial": [
        {
          "mutation": "duplicate_entity_identity",
          "bug": "BUG#13",
          "entity": "Line",
          "composite": true,
          "identity": {
            "batch": "with a \\backslash",
            "sequence": {
              "value": 654
            }
          }
        }
      ]
    },
    {
      "verb": "QaGenerated::Hangar.Reopen",
      "args": {
        "code": {
          "value": "gen-20ccbf00"
        }
      }
    },
    {
      "verb": "QaGenerated::Venue.Open",
      "args": {
        "code": "india charlie echo",
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
      "verb": "QaGenerated::Venue.Rescore",
      "args": {
        "amount": {
          "value": 461
        },
        "code": {
          "value": "india charlie echo"
        }
      }
    },
    {
      "verb": "QaGenerated::Venue.Open",
      "args": {
        "code": "bravo echo",
        "colour": "third"
      }
    },
    {
      "verb": "QaGenerated::Venue.AddLine",
      "args": {
        "batch": [
          3,
          8
        ],
        "sequence": {
          "value": -2147483648
        },
        "code": {
          "value": "golf"
        }
      }
    },
    {
      "verb": "QaGenerated::Venue.Line.Label",
      "args": {
        "label": {
          "value": "golf india"
        },
        "code": {
          "value": "echo"
        },
        "id": "1",
        "to": null
      },
      "adversarial": [
        {
          "mutation": "routing_key",
          "bug": "BUG#7/#16/#8",
          "key": "to",
          "shape": "null",
          "declared": false
        }
      ]
    },
    {
      "verb": "QaGenerated::Venue.Line.Label",
      "args": {
        "label": {
          "value": "foxtrot"
        },
        "code": {
          "value": "golf"
        },
        "id": "1"
      }
    },
    {
      "verb": "QaGenerated::Venue.Line.Label",
      "args": {
        "label": {
          "value": "bravo alpha foxtrot"
        },
        "code": {
          "value": "echo"
        },
        "id": "1"
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
        "flavour": "scribbled"
      },
      "adversarial": [
        {
          "mutation": "refusal_precedence",
          "bug": "BUG#7/#8/#14",
          "mismatched": "code",
          "unknown": "flavour",
          "shape": "mismatch+unknown"
        }
      ]
    },
    {
      "verb": "QaGenerated::Venue.Rescore",
      "args": {
        "amount": {
          "value": 888
        },
        "code": {
          "value": "golf"
        }
      }
    },
    {
      "verb": "QaGenerated::Hangar.Open",
      "args": {
        "code": {
          "value": "alpha"
        }
      }
    },
    {
      "verb": "QaGenerated::Hangar.Open",
      "args": {
        "code": {
        }
      },
      "adversarial": [
        {
          "mutation": "null_value_object",
          "bug": "BUG#14",
          "argument": "code",
          "value_object": "HangarCode",
          "closed_set": false,
          "shape": "empty_object"
        }
      ]
    }
  ],
  "divergences": [
    {
      "field": "instances",
      "ruby": {
        "QaGenerated::Venue#echo": {
          "code": {
            "value": "echo"
          },
          "lines": [
            {
              "batch": {
                "value": "bravo"
              },
              "sequence": {
                "value": 461
              },
              "label": null
            }
          ]
        },
        "QaGenerated::Venue#golf": {
          "code": {
            "value": "golf"
          },
          "lines": [
            {
              "batch": {
                "value": "with a \\backslash"
              },
              "sequence": {
                "value": 654
              },
              "label": null
            }
          ]
        },
        "QaGenerated::Venue#india charlie echo": {
          "code": {
            "value": "india charlie echo"
          },
          "lines": [

          ]
        },
        "QaGenerated::Hangar#hotel hotel juliet": {
          "code": {
            "value": "hotel hotel juliet"
          }
        },
        "QaGenerated::Hangar#with, a comma": {
          "code": {
            "value": "with, a comma"
          }
        },
        "QaGenerated::Hangar#alpha": {
          "code": {
            "value": "alpha"
          }
        }
      },
      "rust": {
        "QaGenerated::Venue#echo": {
          "code": {
            "value": "echo"
          },
          "lines": [
            {
              "batch": {
                "value": "bravo"
              },
              "sequence": {
                "value": 461
              },
              "label": null
            }
          ]
        },
        "QaGenerated::Venue#golf": {
          "code": {
            "value": "golf"
          },
          "lines": [
            {
              "batch": {
                "value": "with a \\backslash"
              },
              "sequence": {
                "value": 654
              },
              "label": null
            },
            {
              "batch": {
                "value": "with a \\backslash"
              },
              "sequence": {
                "value": 654
              },
              "label": null
            }
          ]
        },
        "QaGenerated::Venue#india charlie echo": {
          "code": {
            "value": "india charlie echo"
          },
          "lines": [

          ]
        },
        "QaGenerated::Hangar#alpha": {
          "code": {
            "value": "alpha"
          }
        },
        "QaGenerated::Hangar#hotel hotel juliet": {
          "code": {
            "value": "hotel hotel juliet"
          }
        },
        "QaGenerated::Hangar#with, a comma": {
          "code": {
            "value": "with, a comma"
          }
        }
      }
    },
    {
      "field": "events",
      "ruby": [
        {
          "name": "VenueOpened",
          "aggregate": "QaGenerated::Venue",
          "id": "echo",
          "payload": {
            "code": {
              "value": "echo"
            }
          }
        },
        {
          "name": "VenueLineAdded",
          "aggregate": "QaGenerated::Venue",
          "id": "echo",
          "payload": {
            "batch": {
              "value": "bravo"
            },
            "sequence": {
              "value": 461
            },
            "code": {
              "value": "echo"
            }
          }
        },
        {
          "name": "HangarOpened",
          "aggregate": "QaGenerated::Hangar",
          "id": "hotel hotel juliet",
          "payload": {
            "code": {
              "value": "hotel hotel juliet"
            }
          }
        },
        {
          "name": "VenueOpened",
          "aggregate": "QaGenerated::Venue",
          "id": "golf",
          "payload": {
            "code": {
              "value": "golf"
            }
          }
        },
        {
          "name": "VenueRescored",
          "aggregate": "QaGenerated::Venue",
          "id": "golf",
          "payload": {
            "amount": {
              "value": 566
            },
            "code": {
              "value": "golf"
            }
          }
        },
        {
          "name": "HangarOpened",
          "aggregate": "QaGenerated::Hangar",
          "id": "with, a comma",
          "payload": {
            "code": {
              "value": "with, a comma"
            }
          }
        },
        {
          "name": "VenueLineAdded",
          "aggregate": "QaGenerated::Venue",
          "id": "golf",
          "payload": {
            "batch": {
              "value": "with a \\backslash"
            },
            "sequence": {
              "value": 654
            },
            "code": {
              "value": "golf"
            }
          }
        },
        {
          "name": "VenueRescored",
          "aggregate": "QaGenerated::Venue",
          "id": "echo",
          "payload": {
            "amount": {
              "value": 610
            },
            "code": {
              "value": "echo"
            }
          }
        },
        {
          "name": "VenueOpened",
          "aggregate": "QaGenerated::Venue",
          "id": "india charlie echo",
          "payload": {
            "code": {
              "value": "india charlie echo"
            }
          }
        },
        {
          "name": "VenueRescored",
          "aggregate": "QaGenerated::Venue",
          "id": "india charlie echo",
          "payload": {
            "amount": {
              "value": 461
            },
            "code": {
              "value": "india charlie echo"
            }
          }
        },
        {
          "name": "VenueRescored",
          "aggregate": "QaGenerated::Venue",
          "id": "golf",
          "payload": {
            "amount": {
              "value": 888
            },
            "code": {
              "value": "golf"
            }
          }
        },
        {
          "name": "HangarOpened",
          "aggregate": "QaGenerated::Hangar",
          "id": "alpha",
          "payload": {
            "code": {
              "value": "alpha"
            }
          }
        }
      ],
      "rust": [
        {
          "name": "VenueOpened",
          "aggregate": "QaGenerated::Venue",
          "id": "echo",
          "payload": {
            "code": {
              "value": "echo"
            }
          }
        },
        {
          "name": "VenueLineAdded",
          "aggregate": "QaGenerated::Venue",
          "id": "echo",
          "payload": {
            "batch": {
              "value": "bravo"
            },
            "sequence": {
              "value": 461
            },
            "code": {
              "value": "echo"
            }
          }
        },
        {
          "name": "HangarOpened",
          "aggregate": "QaGenerated::Hangar",
          "id": "hotel hotel juliet",
          "payload": {
            "code": {
              "value": "hotel hotel juliet"
            }
          }
        },
        {
          "name": "VenueOpened",
          "aggregate": "QaGenerated::Venue",
          "id": "golf",
          "payload": {
            "code": {
              "value": "golf"
            }
          }
        },
        {
          "name": "VenueRescored",
          "aggregate": "QaGenerated::Venue",
          "id": "golf",
          "payload": {
            "amount": {
              "value": 566
            },
            "code": {
              "value": "golf"
            }
          }
        },
        {
          "name": "HangarOpened",
          "aggregate": "QaGenerated::Hangar",
          "id": "with, a comma",
          "payload": {
            "code": {
              "value": "with, a comma"
            }
          }
        },
        {
          "name": "VenueLineAdded",
          "aggregate": "QaGenerated::Venue",
          "id": "golf",
          "payload": {
            "batch": {
              "value": "with a \\backslash"
            },
            "sequence": {
              "value": 654
            },
            "code": {
              "value": "golf"
            }
          }
        },
        {
          "name": "VenueRescored",
          "aggregate": "QaGenerated::Venue",
          "id": "echo",
          "payload": {
            "amount": {
              "value": 610
            },
            "code": {
              "value": "echo"
            }
          }
        },
        {
          "name": "VenueLineAdded",
          "aggregate": "QaGenerated::Venue",
          "id": "golf",
          "payload": {
            "batch": {
              "value": "with a \\backslash"
            },
            "sequence": {
              "value": 654
            },
            "code": {
              "value": "golf"
            }
          }
        },
        {
          "name": "VenueOpened",
          "aggregate": "QaGenerated::Venue",
          "id": "india charlie echo",
          "payload": {
            "code": {
              "value": "india charlie echo"
            }
          }
        },
        {
          "name": "VenueRescored",
          "aggregate": "QaGenerated::Venue",
          "id": "india charlie echo",
          "payload": {
            "amount": {
              "value": 461
            },
            "code": {
              "value": "india charlie echo"
            }
          }
        },
        {
          "name": "VenueRescored",
          "aggregate": "QaGenerated::Venue",
          "id": "golf",
          "payload": {
            "amount": {
              "value": 888
            },
            "code": {
              "value": "golf"
            }
          }
        },
        {
          "name": "HangarOpened",
          "aggregate": "QaGenerated::Hangar",
          "id": "alpha",
          "payload": {
            "code": {
              "value": "alpha"
            }
          }
        }
      ]
    },
    {
      "field": "refusals",
      "ruby": [
        {
          "verb": "QaGenerated::Hangar.Open",
          "kind": "TypeMismatch"
        },
        {
          "verb": "QaGenerated::Venue.Line.Label",
          "kind": "NotFound"
        },
        {
          "verb": "QaGenerated::Venue.Prioritize",
          "kind": "InvariantViolation"
        },
        {
          "verb": "QaGenerated::Hangar.Rescore",
          "kind": "TypeMismatch"
        },
        {
          "verb": "QaGenerated::Venue.AddLine",
          "kind": "AlreadyExists"
        },
        {
          "verb": "QaGenerated::Hangar.Reopen",
          "kind": "NotFound"
        },
        {
          "verb": "QaGenerated::Venue.Open",
          "kind": "UnknownArgument"
        },
        {
          "verb": "QaGenerated::Venue.AddLine",
          "kind": "TypeMismatch"
        },
        {
          "verb": "QaGenerated::Venue.Line.Label",
          "kind": "NotFound"
        },
        {
          "verb": "QaGenerated::Venue.Line.Label",
          "kind": "NotFound"
        },
        {
          "verb": "QaGenerated::Venue.Line.Label",
          "kind": "NotFound"
        },
        {
          "verb": "QaGenerated::Hangar.Open",
          "kind": "UnknownArgument"
        },
        {
          "verb": "QaGenerated::Hangar.Open",
          "kind": "TypeMismatch"
        }
      ],
      "rust": [
        {
          "verb": "QaGenerated::Hangar.Open",
          "kind": "TypeMismatch"
        },
        {
          "verb": "QaGenerated::Venue.Line.Label",
          "kind": "NotFound"
        },
        {
          "verb": "QaGenerated::Venue.Prioritize",
          "kind": "InvariantViolation"
        },
        {
          "verb": "QaGenerated::Hangar.Rescore",
          "kind": "TypeMismatch"
        },
        {
          "verb": "QaGenerated::Hangar.Reopen",
          "kind": "NotFound"
        },
        {
          "verb": "QaGenerated::Venue.Open",
          "kind": "UnknownArgument"
        },
        {
          "verb": "QaGenerated::Venue.AddLine",
          "kind": "TypeMismatch"
        },
        {
          "verb": "QaGenerated::Venue.Line.Label",
          "kind": "NotFound"
        },
        {
          "verb": "QaGenerated::Venue.Line.Label",
          "kind": "NotFound"
        },
        {
          "verb": "QaGenerated::Venue.Line.Label",
          "kind": "NotFound"
        },
        {
          "verb": "QaGenerated::Hangar.Open",
          "kind": "UnknownArgument"
        },
        {
          "verb": "QaGenerated::Hangar.Open",
          "kind": "TypeMismatch"
        }
      ]
    }
  ],
  "shrunk_steps": [
    {
      "verb": "QaGenerated::Venue.Open",
      "args": {
        "code": {
          "value": "golf"
        }
      }
    },
    {
      "verb": "QaGenerated::Venue.AddLine",
      "args": {
        "batch": "with a \\backslash",
        "sequence": {
          "value": 654
        },
        "code": {
          "value": "golf"
        }
      },
      "adversarial": [
        {
          "mutation": "routing_key",
          "bug": "BUG#7/#16/#8",
          "key": "to",
          "shape": "null",
          "declared": false
        }
      ]
    },
    {
      "verb": "QaGenerated::Venue.AddLine",
      "args": {
        "batch": "with a \\backslash",
        "sequence": {
          "value": 654
        },
        "code": {
          "value": "golf"
        }
      },
      "adversarial": [
        {
          "mutation": "duplicate_entity_identity",
          "bug": "BUG#13",
          "entity": "Line",
          "composite": true,
          "identity": {
            "batch": "with a \\backslash",
            "sequence": {
              "value": 654
            }
          }
        }
      ]
    }
  ],
  "status": "found",
  "seeds_run": 4
}
```
