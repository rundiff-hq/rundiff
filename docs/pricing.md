# Pricing and packaging direction

## Status

Product direction. Prices, allowance sizes, and credit conversion are not yet commercial contracts.

## Goal

RunDiff pricing should answer a human question:

> How much useful Behavioral Review capacity do I get?

Raw execution minutes do not answer that well because repositories vary dramatically in workload duration, machine size, parallelism, and Evidence Depth.

A two-minute wall-clock run on one worker is not economically equivalent to a two-minute run on sixteen workers.

The product should therefore separate customer-facing value from internal compute accounting.

## Product dimensions

RunDiff pricing has two independent primary dimensions.

### 1. Review Volume

Working plan labels:

- Preview;
- Review 250;
- Review 500;
- Review 1000;
- Enterprise.

The numeric names are provisional.

Review Volume describes how much RunDiff-managed review capacity is included.

### 2. Evidence Depth

Working levels:

- Standard;
- Performance;
- Deep.

Evidence Depth describes how deeply RunDiff observes and compares execution.

A customer with a large repository may need high Review Volume and only Standard evidence.

A small critical service may need low Review Volume and Performance or Deep evidence.

Do not collapse these into one linear tier ladder.

## Preview

Preview should be genuinely useful.

Preferred direction:

~~~text
Preview
  -> customer-funded execution
  -> GitHub Actions or another supported customer orchestrator
  -> Standard evidence by default
  -> RunDiff review surfaces
~~~

Preview has no RunDiff-managed compute allowance by default.

The free tier should not be artificially crippled merely to force an upgrade.

## Review Credits

Review Credits are the working normalized accounting unit for managed execution.

They solve problems that raw minutes cannot:

- different CPU/RAM shapes;
- multiple parallel workers;
- repeated Performance samples;
- different provider billing units;
- baseline/candidate pairing;
- future microVM/container execution differences.

The exact conversion is not yet a public contract.

A conceptual normalization may account for:

~~~text
resource shape
x execution duration
x parallelism
+ other material provider resource dimensions
~~~

Example:

~~~text
4 parallel workers
x 3 minutes each
= approximately 12 worker-minutes before normalization
~~~

This must not be billed as only 3 minutes merely because elapsed wall time was 3 minutes.

## Credits are not the primary UX

Replacing "500 minutes" with "500 credits" does not by itself make pricing understandable.

Credits should be secondary accounting information.

The primary human explanation should be estimated Behavioral Reviews.

Example:

~~~text
Review 500

~100 Behavioral Reviews / month
for a representative workload

5,000 Review Credits included
~~~

The numbers above are illustrative only.

## Repository-specific estimates

After RunDiff has enough repository history, generic estimates should become personalized.

Example:

~~~text
Based on this repository

Median Behavioral Review
  4m 14s

Estimated monthly capacity
  Review 250  -> ~59 reviews
  Review 500  -> ~118 reviews
  Review 1000 -> ~236 reviews
~~~

These numbers are examples of the UX shape, not pricing promises.

Useful statistics may include:

- median Review Credit consumption;
- p90 consumption;
- median wall time;
- selected Evidence Depth;
- typical parallelism;
- baseline reuse rate;
- candidate evidence reuse rate.

## Do not price by PR count

A PR is not a durable workload unit.

A Behavioral Review may evaluate:

- a human PR;
- an AI-generated patch;
- one of many candidate solutions;
- a merge-queue candidate;
- a branch;
- an agent-produced change.

AI-assisted development may create tens or hundreds of candidates where a human team historically created a few PRs.

Therefore "2 PRs per day" may be useful as an illustrative scenario, but it must not be the billing contract.

## Review Workload affects economics

RunDiff should not automatically execute the entire customer CI suite.

A customer may select:

- explicit tests/scenarios;
- changed/related workload;
- smoke flows;
- the full suite.

This changes both time-to-result and Review Credit consumption.

Pricing UX should reinforce:

> Run what matters for the change, not everything that exists in CI.

See RFC 0007.

## Evidence Depth affects consumption

### Standard

Usually one behavioral comparison with broad evidence.

### Performance

May require:

- calibration;
- same-lease pairing;
- repeated samples;
- interleaving;
- fixed parallelism.

Therefore Performance can consume more Review Credits than Standard.

### Deep

May require controlled RunDiff Fleet or customer-hosted privileged infrastructure and deeper sensors.

Deep can have a distinct credit multiplier or capability fee in the future, but the exact commercial mechanism is undecided.

## Pricing calculator

The pricing page should include a calculator.

Conceptual inputs:

~~~text
Typical Review Workload duration
  [ 5 min ]

Behavioral Reviews
  [ 4 / working day ]

Evidence Depth
  [ Performance ]

Typical parallelism
  [ 2 workers ]

Working days
  [ 22 ]
~~~

Output:

~~~text
Estimated monthly usage
  ~N Review Credits

Suggested capacity
  Review 500
~~~

The calculation should clearly label estimates and assumptions.

## Existing repository calculator

After installation, the best calculator is based on observed repository history.

Example:

~~~text
Your repository

Typical Standard review
  31 credits

Typical Performance review
  58 credits

Review 500
  ~161 Standard reviews
  ~86 Performance reviews
~~~

Again, numbers are illustrative.

## Managed provider abstraction

Customers should not normally buy infrastructure brands.

Do not create plan names such as:

- Cloudflare Plan;
- Namespace Plan;
- E2B Plan.

Preferred UX:

~~~text
Execution
  Automatic
~~~

RunDiff chooses an Execution Plan according to compatibility, policy, stability, cost, and requested Evidence Depth.

Advanced/Enterprise policy may constrain execution providers without changing the basic pricing model.

## Pricing page information architecture

Recommended page structure:

1. hero;
2. Review Volume selector/cards;
3. Evidence Depth selector/explainer;
4. usage calculator;
5. "How pricing works" two-axis explanation;
6. automatic execution explanation;
7. plan comparison table;
8. FAQ;
9. final CTA.

The page should make the two dimensions obvious without rendering every possible combination as a separate plan card.

## Visual direction

Current design preference for the pricing experience:

- premium modern SaaS;
- strong black/white/green foundation;
- bright multicolor accents for icons, pills, and small markers;
- generous spacing;
- clear grid and card hierarchy;
- polished segmented controls/toggles;
- rounded controls/cards where appropriate;
- strong typography;
- playful detail without visual clutter.

Figma's current pricing page is a visual reference for hierarchy, density, color energy, and multi-dimensional pricing presentation.

RunDiff must remain visually original:

- no Figma branding;
- no Figma logo;
- no copied product names;
- no copied illustrations or proprietary assets;
- no verbatim page reproduction.

Use the reference as inspiration for design language, not as a clone specification.

## Candidate copy concepts

Useful product language:

~~~text
How much do you review?
Preview | 250 | 500 | 1000 | Enterprise

How deep should RunDiff look?
Standard | Performance | Deep
~~~

and:

~~~text
Automatic execution
RunDiff chooses the right execution plan for each review.
~~~

and, after repository history:

~~~text
Based on your repository:
~118 Behavioral Reviews / month
~~~

## Open commercial questions

1. What is one Review Credit?
2. What standard machine/resource shape anchors normalization?
3. Do memory/disk/network receive explicit weights or remain hidden behind normalized cost?
4. Does Performance consume credits purely by actual execution or by a simple product multiplier?
5. Does Deep use credits, an add-on, or both?
6. What included Review Credit amounts map to the final plan names?
7. What repository-history threshold is enough for personalized estimates?
8. How much provider cost variation should RunDiff absorb rather than expose?
9. Should unused credits roll over?
10. How should imported candidate evidence reduce credit consumption?

## Related work

- RFC 0004: Execution planning, compute, placement, and evidence strategy
- RFC 0007: Repository configuration, review workload, and source-code boundary
- docs/product.md
- docs/definitions.md
