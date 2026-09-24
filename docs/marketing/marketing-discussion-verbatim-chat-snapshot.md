# RunDiff Marketing Discussion - Verbatim Chat Snapshot

## Status

Verbatim snapshot of the original assistant response from this conversation, preserved for later comparison.

The content below is intentionally not normalized, rewritten, reorganized, or reconciled with later documents.

---

Я б будував маркетинг RunDiff не навколо "ми підтримуємо 12 мов", а навколо значно сильнішої ідеї:

**RunDiff перевіряє поведінку системи, а не мову, якою вона написана.**

Це важлива відмінність. Саме вона дозволяє вам через рік додати Java, Rust, .NET, PHP, Elixir, containers, serverless і не переписувати позиціонування.

## 1. Як показувати мови на homepage

Я б **не робив великий список мов як центральний елемент**:

> Ruby · Python · Go · Node.js · Java · Rust · ...

Це відразу робить RunDiff схожим на linting/testing/observability SDK.

Натомість homepage:

### Hero

**Know what changed before you merge.**

Baseline and candidate.  
Same scenario.  
Real runtime evidence.  
Behavioral diff before production.

А трохи нижче:

**Works across your stack.**

`Ruby` `Python` `Node.js` `Go` `Java` `Rust` `Containers`

І останній chip:

**+ anything you can run**

Оце, на мою думку, дуже сильна фраза для RunDiff.

Бо ваша реальна абстракція - не programming language.

Вона приблизно така:

```text
Runnable workload
      ↓
Baseline + Candidate
      ↓
Same scenario
      ↓
Runtime evidence
      ↓
Behavioral diff
```

Тобто homepage може навіть мати:

> **If it runs, RunDiff can compare it.**

А вже `/docs/runtimes` або `/integrations` може містити нормальну матрицю:

| Runtime | Status | Signals |
|---|---|---|
| Ruby / Rails | First-class | SQL, HTTP, runtime, OTEL |
| Node.js | Supported | HTTP, runtime, OTEL |
| Go | Supported | HTTP, runtime, OTEL |
| Python | Supported | SQL, HTTP, runtime, OTEL |
| Java | Planned | ... |
| Rust | Planned | ... |
| Docker | Generic | process/network/CPU/memory |

Тут важливо чесно розрізняти **generic support** і **deep instrumentation**.

Наприклад, Docker application RunDiff може запустити вже зараз, але Rails sensor може знати значно більше про SQL queries, ActiveRecord та application behavior.

Це нормальна і навіть сильна модель.

---

# 2. Чи говорити на homepage про Go executor

Я б **ні**.

Те, що executor написаний на Go, для клієнта практично implementation detail.

Не:

> Powered by a Go executor

А:

> **Isolated, reproducible execution**

або

> **Run the same workload against baseline and candidate.**

Go можна згадувати:

- у `/docs/architecture`
- engineering blog
- GitHub README
- "How RunDiff works"
- technical deep dive

І там це вже цікаво:

> Why we built the RunDiff executor in Go

Це окрема чудова engineering article.

Але вона продає **інженерну компетентність RunDiff**, а не продуктову можливість.

---

# 3. GitHub Actions і Cloudflare Containers

Тут тонший момент.

**GitHub Actions я б показував на homepage.**

Але не тому, що там працює executor.

А тому що це user-facing integration:

```text
Pull Request
    ↓
RunDiff
    ↓
Behavioral Diff
    ↓
GitHub Check
```

Наприклад:

> **Built for pull requests.**
>
> RunDiff compares your baseline and candidate and reports behavioral changes directly on the PR.

GitHub logo тут доречний.

---

Cloudflare Containers я б **не ставив у головний messaging**.

Тому що:

> Runs on Cloudflare Containers

змушує людину думати про вашу інфраструктуру замість своєї проблеми.

Це можна показувати десь нижче:

### Flexible execution

```text
GitHub Actions
Cloud execution
Self-hosted
BYOC
```

І от **це вже стратегічно дуже сильна штука**.

Причому я б навіть не робив Cloudflare брендом продуктового рівня.

Архітектурна модель краща:

```text
RunDiff Control Plane

Execution Providers
├─ GitHub Actions
├─ RunDiff Cloud
├─ BYOC
└─ Self-hosted
```

А RunDiff Cloud сьогодні може бути Cloudflare Containers, завтра AWS Firecracker, Fly Machines або ваша власна інфраструктура.

Marketing не повинен зв'язувати вам руки.

---

# 4. Найцікавіша частина - блог

Тут у RunDiff може бути **надзвичайно сильний content moat**.

Я б взагалі не робив блог типу:

> Product updates  
> We launched GitHub integration  
> RunDiff 0.8 released

Це теж потрібно, але другорядне.

Основний блог RunDiff я б перетворив на:

# Runtime Regression Library

або навіть:

# Behavioral Failure Library

Тобто каталог того:

> **Як хороший на вигляд код створює погану поведінку системи.**

І це буквально те, що RunDiff повинен знаходити.

---

# 5. У кожної статті одна структура

Це важливо.

Зробіть свою **ontology of regressions**.

Наприклад:

```text
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
```

Тоді кожна стаття стає одночасно:

- educational content
- SEO page
- System Design material
- documentation RunDiff
- use case
- demo scenario
- future rule/detector definition

Оце дуже цікаво.

**Ваш блог може поступово перетворитися на taxonomy самого RunDiff engine.**

---

# 6. Я б визначив приблизно такі Families

Не 30 випадкових статей.

Зробіть 8-10 сімейств.

```text
Database
Networking
API
Concurrency
CPU
Memory
I/O
Caching
Queues / Async
Reliability
```

І вже всередині них patterns.

Наприклад:

### Database

```text
N+1 queries
Missing index
Over-fetching
SELECT *
Wrong join strategy
Repeated aggregation
Application-side aggregation
Lock contention
Long transactions
Connection pool exhaustion
```

### Networking

```text
Chatty HTTP
Sequential requests
Connection churn
DNS regression
Retry storms
Missing timeout
Payload explosion
Compression regression
Cross-region call
```

### API

```text
Breaking response shape
Extra upstream call
Pagination regression
Fan-out explosion
Retry amplification
Synchronous dependency
Timeout propagation
Rate-limit regression
```

### CPU

```text
Accidental O(n²)
Repeated serialization
Regex backtracking
Unnecessary parsing
Application-side sorting
Repeated cryptography
Compression overhead
Busy polling
```

### Memory

```text
Unbounded collection
Object allocation explosion
Large response buffering
Cache growth
Memory leak
Duplicate representation
```

### Concurrency

```text
Race condition
Lock contention
Thundering herd
Duplicate jobs
Lost update
Deadlock
Non-idempotent retry
```

### Async / Queues

```text
Synchronous work that should be async
Job explosion
Retry storm
Poison message
Queue fan-out
Long-running worker
Missing idempotency
```

Це вже десятки статей.

---

# 7. Перші десять я б вибрав дуже конкретно

І саме в такому приблизно розвитку складності.

### 01 - The N+1 Query: When One Line Creates 1,000 Queries

Family: Database  
Category: Query amplification

Це ідеальна перша стаття, бо проблему розуміє майже кожен backend engineer.

І дуже просто показати RunDiff:

```text
Baseline    17 SQL queries
Candidate   31 SQL queries

+82.4%
```

Це майже ваша canonical demo.

---

### 02 - When Your Application Does the Database's Job

Family: Database  
Category: Computation placement

Приклад:

Ruby/Python:

```ruby
orders.to_a.sum(&:total)
```

проти:

```sql
SELECT SUM(total)
```

Але стаття не повинна казати "SQL завжди краще".

Показати tradeoff:

```text
rows transferred
CPU
memory
latency
DB CPU
application CPU
```

Ідеальна System Design стаття.

---

### 03 - The Hidden Cost of One More API Call

Family: Networking  
Category: Request amplification

Було:

```text
request
 └─ API A
```

Стало:

```text
request
 ├─ API A
 ├─ API B
 └─ API C
```

Код виглядає невинно.

Runtime behavior змінюється радикально.

Це буквально RunDiff thesis.

---

### 04 - Sequential vs Parallel I/O

Family: Networking  
Category: Execution strategy

```text
A → B → C
```

проти:

```text
A ─┐
B ─┼→ aggregate
C ─┘
```

Latency:

```text
120 + 90 + 140 ms
```

vs приблизно max latency.

Ruby, Node, Go, Python приклади.

---

### 05 - This Should Have Been a Background Job

Family: Architecture  
Category: Sync → Async

Email, thumbnail generation, webhook processing, report generation.

Тут чудово вводиться:

```text
critical request path
```

і

```text
non-critical work
```

---

### 06 - Retry Storms: When Reliability Code Causes an Outage

Family: Reliability  
Category: Retries

Дуже хороший матеріал.

Пояснити:

```text
timeout
↓
retry
↓
more load
↓
more timeout
↓
more retry
```

і:

- exponential backoff
- jitter
- retry budgets
- idempotency
- circuit breaking

---

### 07 - The Missing Index That Passed Every Test

Family: Database  
Category: Access path

Тут прекрасний headline:

> Your tests passed. Your code review passed. Your database did not.

І пояснити різницю між:

```text
correctness
```

і

```text
runtime behavior
```

---

### 08 - When O(n) Quietly Becomes O(n²)

Family: CPU  
Category: Algorithmic regression

Дуже хороший міст між:

- algorithms
- System Design
- production
- RunDiff

Наприклад:

```ruby
users.map do |user|
  permissions.find { ... }
end
```

---

### 09 - Why Timeouts Are Part of Your Architecture

Family: Networking  
Category: Failure boundaries

Connect/read/write/overall timeout.

Потім:

```text
service A
  ↓ 5s
service B
  ↓ 10s
service C
```

і timeout budget.

---

### 10 - The Code Diff Was Small. The Behavioral Diff Wasn't.

Оце я б зробив **manifesto article**.

Не конкретна проблема.

Вона пояснює RunDiff.

Наприклад:

```diff
- users.each
+ users.includes(:projects).each
```

Може бути маленький code diff із величезною behavioral зміною.

Або навпаки.

Головна теза:

> **Code diff tells you what text changed.  
> Behavioral diff tells you what the system changed.**

Це одна з найсильніших фраз, які RunDiff може собі забрати.

---

# 8. А потім можна зробити серії

Наприклад:

## Database Regressions

```text
#11 Query amplification
#12 Missing indexes
#13 Connection pools
#14 Lock contention
#15 Long transactions
#16 Read amplification
#17 Write amplification
```

## Network Regressions

```text
#18 Chatty APIs
#19 Retry storms
#20 Payload growth
#21 Connection churn
#22 Sequential I/O
#23 DNS/TLS overhead
```

## Distributed Systems

```text
#24 Idempotency
#25 Duplicate delivery
#26 Out-of-order events
#27 Lost updates
#28 Thundering herd
#29 Backpressure
#30 Circuit breakers
```

Ось вам уже **30 статей**, і жодна не виглядає натягнутою рекламою.

---

# 9. Не рекламувати RunDiff у кожному абзаці

Це дуже важливо.

80-90% статті повинно бути:

> Here's the engineering problem.

І лише в кінці:

## Catching it before production

```text
Baseline
23 queries
420 ms
7 MB allocated

Candidate
47 queries
690 ms
12 MB allocated
```

RunDiff:

```text
SQL queries   +104%
Latency        +64%
Allocations    +71%
```

**BLOCK**

Тобто RunDiff не повинен говорити:

> Buy RunDiff because N+1 is bad.

Натомість:

> Ось ґрунтовна стаття про N+1.  
> До речі, ось як behavioral comparison може побачити її на PR.

Це набагато сильніше.

---

# 10. І тут народжується ще одна дуже хороша частина продукту

Згодом те, що зараз є статтею:

```text
N+1
Retry storm
HTTP amplification
SQL amplification
CPU regression
Memory regression
```

може стати **RunDiff Knowledge Base**.

А потім:

```text
Detected pattern:
Possible N+1 query

Evidence:
GET /projects

baseline:
17 SQL queries

candidate:
31 SQL queries

Most amplified query:
SELECT "users".* FROM ...

Learn more:
rundiff.com/library/n-plus-one
```

Тобто marketing content стає частиною продукту.

Це дуже сильний flywheel:

```text
Engineering problem
       ↓
Blog article
       ↓
RunDiff detector
       ↓
PR finding
       ↓
Link to explanation
       ↓
Developer learns
       ↓
RunDiff becomes useful
```

---

# 11. System Design напрямок я б точно робив

І навіть окремий розділ:

**RunDiff Engineering Library**

```text
Runtime Regressions
System Design
Databases
Distributed Systems
Performance
Reliability
```

І статті можуть бути не лише "ось баг".

Наприклад:

> When should computation live in SQL?

> When should work become asynchronous?

> When should you cache?

> When should you batch requests?

> When is parallelism actually faster?

> How large should a database transaction be?

> What belongs on the request critical path?

> How should retry budgets work?

> What does backpressure actually solve?

> Why idempotency is not just about payments

Це вже material рівня Senior / Staff Engineer.

І саме така аудиторія потенційно може стати вашим champion усередині компанії.

---

## І в результаті я бачу homepage приблизно так

```text
RunDiff

Know what changed before you merge.

Compare baseline and candidate under the same scenario.
See behavioral changes before they reach production.

[ Get started ] [ See an example ]

────────────────────────────

CODE DIFF
14 files changed

BEHAVIORAL DIFF

SQL queries       17 → 31     +82%
HTTP calls         4 → 7      +75%
p95 latency      181 → 294ms  +62%
Memory            42 → 44MB    +5%

Decision: BLOCK

────────────────────────────

Works across your stack

Ruby  Python  Node.js  Go  Java  Rust  Containers
+ anything you can run

────────────────────────────

Catch changes tests don't describe.

Database
Networking
CPU
Memory
API
Concurrency
Queues

────────────────────────────

Built for pull requests.

GitHub → RunDiff → Behavioral Diff → Check

────────────────────────────

Learn what runtime regressions look like.

N+1 Queries
Retry Storms
API Amplification
Missing Indexes
Sequential I/O
O(n²) Regressions

[ Explore the Runtime Regression Library ]
```

І я б **не писав на цій сторінці ні "executor written in Go", ні "Cloudflare Containers"**.

Це речі другого/третього рівня.

А головна історія RunDiff набагато чистіша:

**Git tells you what code changed.  
RunDiff tells you what behavior changed.**

І от навколо цього, як на мене, вже реально можна побудувати не тільки landing page, а цілу категорію продукту.
