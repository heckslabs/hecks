# generated_keyword_aggregate

Promoted from a `bin/qa_generated_domains` finding — generated, not
hand-written. The bluebook is the domain-shrunk minimal form of the
generated domain that surprised; `QaGenerated` was renamed to
`GeneratedKeywordAggregate` and nothing else changed.

## Blueprint

```json
{
  "aggregates": [
    {
      "name": "Crate",
      "identity": [
        "code"
      ],
      "vos": {
        "CrateCode": {
          "kind": "string"
        },
        "CrateScore": {
          "kind": "integer"
        },
        "CrateNote": {
          "kind": "string"
        },
        "CratePriority": {
          "kind": "closed",
          "members": [
            "low",
            "high"
          ]
        }
      },
      "attributes": [
        {
          "name": "code",
          "type": "CrateCode"
        },
        {
          "name": "score",
          "type": "CrateScore",
          "default": 0
        },
        {
          "name": "note",
          "type": "CrateNote",
          "optional": true
        },
        {
          "name": "priority",
          "type": "CratePriority",
          "optional": true
        }
      ],
      "references": [

      ],
      "lifecycle": null,
      "invariants": [
        {
          "label": "a score is never negative",
          "expr": "score.value >= 0",
          "requires": [
            "attribute:Crate.score"
          ]
        }
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
              "type": "CrateCode"
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
            "CrateOpened"
          ],
          "role": "Manager"
        },
        {
          "name": "Rescore",
          "creates": false,
          "references": [

          ],
          "args": [
            {
              "name": "amount",
              "type": "CrateScore"
            }
          ],
          "givens": [

          ],
          "sets": [
            {
              "target": "score",
              "to": "amount",
              "requires": [
                "attribute:Crate.score"
              ]
            }
          ],
          "emits": [
            "CrateRescored"
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
              "type": "CrateNote",
              "optional": true
            }
          ],
          "givens": [

          ],
          "sets": [
            {
              "target": "note",
              "requires": [
                "attribute:Crate.note"
              ]
            }
          ],
          "emits": [
            "CrateAnnotated"
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
              "type": "CratePriority"
            }
          ],
          "givens": [

          ],
          "sets": [
            {
              "target": "priority",
              "requires": [
                "attribute:Crate.priority"
              ]
            }
          ],
          "emits": [
            "CratePrioritized"
          ],
          "role": "Clerk"
        }
      ],
      "queries": [

      ]
    }
  ],
  "policies": [

  ],
  "seed": 12,
  "forms": [
    "has_default",
    "has_optional"
  ]
}
```

## Finding

```json
{
  "status": "found",
  "mode": "rust_build",
  "signature": [
    "rust_build"
  ],
  "divergences": [
    {
      "field": "rust_build",
      "detail": "error: expected identifier, found keyword `crate`\nerror: expected identifier, found keyword `crate`\nerror: expected identifier, found keyword `crate`\nerror: expected identifier, found keyword `crate`\nerror: expected identifier, found keyword `crate`\nerror[E0433]: failed to resolve: `crate` in paths can only be used in start position\nerror[E0433]: failed to resolve: `crate` in paths can only be used in start position\nerror[E0433]: failed to resolve: `crate` in paths can only be used in start position\nerror[E0433]: failed to resolve: `crate` in paths can only be used in start position\nerror[E0433]: failed to resolve: `crate` in paths can only be used in start position\nerror[E0433]: failed to resolve: `crate` in paths can only be used in start position\nerror[E0433]: failed to resolve: `crate` in paths can only be used in start position\n"
    }
  ],
  "steps": [

  ]
}
```
