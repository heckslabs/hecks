# generated_revalued_shape

Promoted from a `bin/qa_generated_domains` finding — generated, not
hand-written. The bluebook is the domain-shrunk minimal form of the
generated domain that surprised; `QaGenerated` was renamed to
`GeneratedRevaluedShape` and nothing else changed.

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
        "VenueHandle": {
          "kind": "string"
        }
      },
      "attributes": [
        {
          "name": "code",
          "type": "HangarCode"
        }
      ],
      "references": [
        "Venue"
      ],
      "lifecycle": {
        "field": "status",
        "default": "open",
        "transitions": [
          {
            "command": "Reopen",
            "to": "open",
            "from": [
              "closed"
            ],
            "requires": [
              "command:Hangar.Reopen"
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
            "Venue"
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
            },
            {
              "target": "venue",
              "requires": [
                "reference:Hangar->Venue"
              ]
            }
          ],
          "emits": [
            "HangarOpened"
          ]
        },
        {
          "name": "Repoint",
          "creates": false,
          "references": [

          ],
          "args": [
            {
              "name": "venue",
              "type": "VenueHandle"
            }
          ],
          "givens": [

          ],
          "sets": [
            {
              "target": "venue",
              "requires": [
                "reference:Hangar->Venue"
              ]
            }
          ],
          "emits": [
            "HangarRepointed"
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
                "lifecycle:Hangar"
              ]
            }
          ],
          "order_by": "code"
        }
      ]
    },
    {
      "name": "Venue",
      "identity": [
        "code"
      ],
      "vos": {
        "VenueCode": {
          "kind": "string"
        }
      },
      "attributes": [
        {
          "name": "code",
          "type": "VenueCode"
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
        }
      ],
      "queries": [

      ]
    }
  ],
  "policies": [

  ],
  "seed": 1009,
  "forms": [
    "revalued_reference",
    "has_query"
  ]
}
```

## Finding

```json
{
  "seed": 4,
  "mode": "differential",
  "signature": [
    "instances",
    "instances:QaGenerated::Hangar",
    "queries",
    "queries:QaGenerated::Hangar.Listed"
  ],
  "steps": [
    {
      "verb": "QaGenerated::Venue.Open",
      "args": {
        "code": [
          8,
          8
        ],
        "flavour": "red"
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
      "query": "QaGenerated::Hangar.Listed",
      "args": {
      }
    },
    {
      "verb": "QaGenerated::Venue.Open",
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
      "verb": "QaGenerated::Venue.Open",
      "args": {
        "code": {
        }
      },
      "adversarial": [
        {
          "mutation": "null_value_object",
          "bug": "BUG#14",
          "argument": "code",
          "value_object": "VenueCode",
          "closed_set": false,
          "shape": "empty_object"
        }
      ]
    },
    {
      "query": "QaGenerated::Hangar.Listed",
      "args": {
      }
    },
    {
      "query": "QaGenerated::Hangar.Listed",
      "args": {
      }
    },
    {
      "verb": "QaGenerated::Venue.Open",
      "args": {
        "code": {
          "value": "delta"
        }
      }
    },
    {
      "verb": "QaGenerated::Hangar.Open",
      "args": {
        "code": {
          "value": "x"
        }
      },
      "adversarial": [
        {
          "mutation": "omit_mapped_argument",
          "bug": "BUG#12",
          "argument": "venue",
          "optional": false
        }
      ]
    },
    {
      "verb": "QaGenerated::Venue.Open",
      "args": {
        "code": {
          "value": "golf hotel hotel"
        }
      }
    },
    {
      "verb": "QaGenerated::Venue.Open",
      "args": {
        "code": {
          "value": "juliet"
        }
      }
    },
    {
      "query": "QaGenerated::Hangar.Listed",
      "args": {
      }
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
      "verb": "QaGenerated::Venue.Open",
      "args": {
        "code": [
          7,
          2
        ],
        "id": "[7, 2]"
      },
      "adversarial": [
        {
          "mutation": "routing_key",
          "bug": "BUG#7/#16/#8",
          "key": "id",
          "shape": "scalar",
          "declared": false
        }
      ]
    },
    {
      "verb": "QaGenerated::Hangar.Open",
      "args": {
        "venue": "golf hotel hotel",
        "code": {
          "value": "india echo echo"
        }
      }
    },
    {
      "verb": "QaGenerated::Hangar.Reopen",
      "args": {
        "code": {
          "value": "india echo echo"
        }
      }
    },
    {
      "verb": "QaGenerated::Hangar.Open",
      "args": {
        "venue": "echo",
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
        "code": [
          1,
          10
        ]
      }
    },
    {
      "verb": "QaGenerated::Venue.Open",
      "args": {
        "code": {
          "value": "charlie"
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
      "verb": "QaGenerated::Hangar.Repoint",
      "args": {
        "venue": "echo",
        "code": {
          "value": "india echo echo"
        }
      }
    },
    {
      "verb": "QaGenerated::Hangar.Open",
      "args": {
        "venue": "golf hotel hotel",
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
      "query": "QaGenerated::Hangar.Listed",
      "args": {
      }
    },
    {
      "verb": "QaGenerated::Hangar.Repoint",
      "args": {
        "code": {
          "value": "india echo echo"
        }
      }
    },
    {
      "verb": "QaGenerated::Venue.Open",
      "args": {
        "code": {
          "value": [
            "nested",
            "array"
          ]
        },
        "colour": "third"
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
      "verb": "QaGenerated::Hangar.Reopen",
      "args": {
        "code": {
          "value": "gen-93257f22"
        }
      }
    },
    {
      "verb": "QaGenerated::Hangar.Open",
      "args": {
        "venue": "echo",
        "code": {
          "value": "juliet bravo foxtrot"
        }
      }
    }
  ],
  "divergences": [
    {
      "field": "instances",
      "ruby": {
        "QaGenerated::Hangar#india echo echo": {
          "code": {
            "value": "india echo echo"
          },
          "venue": {
            "value": "echo"
          },
          "status": "open"
        },
        "QaGenerated::Hangar#juliet bravo foxtrot": {
          "code": {
            "value": "juliet bravo foxtrot"
          },
          "venue": "echo",
          "status": "open"
        },
        "QaGenerated::Venue#delta": {
          "code": {
            "value": "delta"
          }
        },
        "QaGenerated::Venue#golf hotel hotel": {
          "code": {
            "value": "golf hotel hotel"
          }
        },
        "QaGenerated::Venue#juliet": {
          "code": {
            "value": "juliet"
          }
        },
        "QaGenerated::Venue#echo": {
          "code": {
            "value": "echo"
          }
        },
        "QaGenerated::Venue#charlie": {
          "code": {
            "value": "charlie"
          }
        }
      },
      "rust": {
        "QaGenerated::Hangar#india echo echo": {
          "code": {
            "value": "india echo echo"
          },
          "venue": "echo",
          "status": "open"
        },
        "QaGenerated::Hangar#juliet bravo foxtrot": {
          "code": {
            "value": "juliet bravo foxtrot"
          },
          "venue": "echo",
          "status": "open"
        },
        "QaGenerated::Venue#charlie": {
          "code": {
            "value": "charlie"
          }
        },
        "QaGenerated::Venue#delta": {
          "code": {
            "value": "delta"
          }
        },
        "QaGenerated::Venue#echo": {
          "code": {
            "value": "echo"
          }
        },
        "QaGenerated::Venue#golf hotel hotel": {
          "code": {
            "value": "golf hotel hotel"
          }
        },
        "QaGenerated::Venue#juliet": {
          "code": {
            "value": "juliet"
          }
        }
      }
    },
    {
      "field": "queries",
      "ruby": [
        {
          "query": "QaGenerated::Hangar.Listed",
          "args": {
          },
          "rows": [

          ],
          "reference_rows": [

          ]
        },
        {
          "query": "QaGenerated::Hangar.Listed",
          "args": {
          },
          "rows": [

          ],
          "reference_rows": [

          ]
        },
        {
          "query": "QaGenerated::Hangar.Listed",
          "args": {
          },
          "rows": [

          ],
          "reference_rows": [

          ]
        },
        {
          "query": "QaGenerated::Hangar.Listed",
          "args": {
          },
          "rows": [

          ],
          "reference_rows": [

          ]
        },
        {
          "query": "QaGenerated::Hangar.Listed",
          "args": {
          },
          "rows": [
            {
              "code": {
                "value": "india echo echo"
              },
              "venue": {
                "value": "echo"
              },
              "status": "open",
              "id": "india echo echo"
            }
          ],
          "reference_rows": [
            {
              "code": {
                "value": "india echo echo"
              },
              "venue": {
                "value": "echo"
              },
              "status": "open",
              "id": "india echo echo"
            }
          ]
        }
      ],
      "rust": [
        {
          "query": "QaGenerated::Hangar.Listed",
          "args": {
          },
          "rows": [

          ],
          "reference_rows": [

          ]
        },
        {
          "query": "QaGenerated::Hangar.Listed",
          "args": {
          },
          "rows": [

          ],
          "reference_rows": [

          ]
        },
        {
          "query": "QaGenerated::Hangar.Listed",
          "args": {
          },
          "rows": [

          ],
          "reference_rows": [

          ]
        },
        {
          "query": "QaGenerated::Hangar.Listed",
          "args": {
          },
          "rows": [

          ],
          "reference_rows": [

          ]
        },
        {
          "query": "QaGenerated::Hangar.Listed",
          "args": {
          },
          "rows": [
            {
              "id": "india echo echo",
              "code": {
                "value": "india echo echo"
              },
              "venue": "echo",
              "status": "open"
            }
          ],
          "reference_rows": [
            {
              "id": "india echo echo",
              "code": {
                "value": "india echo echo"
              },
              "venue": "echo",
              "status": "open"
            }
          ]
        }
      ]
    }
  ],
  "shrunk_steps": [
    {
      "verb": "QaGenerated::Venue.Open",
      "args": {
        "code": {
          "value": "golf hotel hotel"
        }
      }
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
      "verb": "QaGenerated::Hangar.Open",
      "args": {
        "venue": "golf hotel hotel",
        "code": {
          "value": "india echo echo"
        }
      }
    },
    {
      "verb": "QaGenerated::Hangar.Repoint",
      "args": {
        "venue": "echo",
        "code": {
          "value": "india echo echo"
        }
      }
    },
    {
      "query": "QaGenerated::Hangar.Listed",
      "args": {
      }
    }
  ],
  "status": "found",
  "seeds_run": 4
}
```
