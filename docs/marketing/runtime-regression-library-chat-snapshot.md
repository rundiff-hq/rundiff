# RunDiff Runtime Regression Library - Chat Snapshot

## Status

Exact conversation snapshot preserved for later comparison.

This is not a finalized editorial plan. It intentionally keeps the examples and series structure from the original chat discussion before later refinement.

---

## Ontology example from chat

~~~text
Family
  Database

Category
  Query amplification

Pattern
  N+1

Signal
  SQL query count

Typical change
  17 → 31 queries

Impact
  latency / DB load / cost

Detection
  baseline vs candidate

Remediation
  preload / join / batching / redesign
~~~

The idea attached to this example was that one article can simultaneously become:

- educational content
- SEO page
- System Design material
- RunDiff documentation
- detector/rule explanation
- use case
- future knowledge-base entry

---

## Series concept from chat

### Database Regressions

~~~text
#11 Query amplification
#12 Missing indexes
#13 Connection pools
#14 Lock contention
#15 Long transactions
#16 Read amplification
#17 Write amplification
~~~

### Network Regressions

~~~text
#18 Chatty APIs
#19 Retry storms
#20 Payload growth
#21 Connection churn
#22 Sequential I/O
#23 DNS/TLS overhead
~~~

### Distributed Systems

~~~text
#24 Idempotency
#25 Duplicate delivery
#26 Out-of-order events
#27 Lost updates
#28 Thundering herd
#29 Backpressure
#30 Circuit breakers
~~~

---

## Why preserve this separately

The refined Runtime Regression Library plan may reorganize article titles, numbering, families, categories, and signals.

This snapshot must remain unchanged so future versions can be compared against the original conversational concept rather than against memory.

Compare future proposals against this snapshot for:

1. simplicity of the family structure;
2. clarity of article naming;
3. breadth across database, networking, and distributed systems;
4. usefulness as a learning path;
5. fit with RunDiff Findings, Diagnoses, and rule documentation;
6. whether refinement improved the concept or merely made it more complicated.
