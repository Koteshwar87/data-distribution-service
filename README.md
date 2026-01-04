# data-distribution-service

Async Export Pipeline (Queue + Worker + Postgres + S3)

## 1. Problem statement

High-frequency clients fetch large datasets by issuing many concurrent paginated API calls. This creates sustained DB pressure and limits overall stability.

We replace that pattern with an asynchronous export job:

- Client submits one request containing multiple keys and explicit effective dates per key.
- The system creates a job and schedules independent work units (“chunks”) via a queue.
- Workers process chunks in parallel (across containers and threads), call a non-paginated DB function, and write CSV files to S3.
- The job completes only when every chunk has completed successfully.

This pipeline is built to be correct under retries, safe under crashes, and bounded by DB limits.

---

## 2. Core concepts (strict definitions)

### 2.1 Job

A job = one API submission.

A job contains N chunks derived from the request body.

### 2.2 Chunk

A chunk = one (key, effectiveDate) pair.

One chunk produces exactly:

- One DB call
- One output CSV file at a deterministic S3 path

### 2.3 Deterministic output path

Deterministic file paths are mandatory to prevent duplicates and enable reuse.

File naming rule:

- File name: `<KEY>_<YYYYMMDD>.csv`
- Folder rule under base path: `YYYY/MM/DD/`

Example:

- base path: `s3://<bucket>/<basePath>/`
- key = `ABC`, date = `20250215`
- output key: `s3://<bucket>/<basePath>/2025/02/15/ABC_20250215.csv`

---

## 3. Components

### 3.1 api-svc (Spring Boot)

Responsibilities:

- Validate request
- Create a job record
- Expand request into chunk rows
- Publish one queue message per chunk
- Provide job status endpoint

Non-responsibilities:

- Does NOT call the export DB function
- Does NOT generate files

### 3.2 wrk-svc (Spring Boot)

Responsibilities:

- Consume queue messages
- Ensure idempotency using DB claim+lease
- Optionally reuse existing files
- Call export DB function (non-paginated)
- Stream results into CSV
- Write file to deterministic S3 location
- Mark chunk DONE/FAILED in DB

### 3.3 mq (ActiveMQ queue)

- Queue distributes chunks to competing consumers.
- A message is delivered to only one consumer at a time.
- Messages can be redelivered after failures (normal behavior).

### 3.4 pg (Postgres)

- System of record for job and chunk state.
- Holds chunk statuses and retry counts.
- (Optional) Holds file reuse cache.

### 3.5 s3 (Object storage)

- Stores output CSV files at deterministic paths.

## 5. Queue contract

### 5.1 Queue name

- Work queue: `job.chunk.work`
- Parking queue (DLQ-lite, recommended): `job.chunk.parking`

### 5.2 Message payload (one message = one chunk)

---

## 4. API contracts

### 4.1 Create job

`POST /jobs`

**Request**

json { "items": , "output": { "format": "CSV" } }

**Validation rules (non-negotiable)**

- `items` must be non-empty
- For each item:
  - `key` must be non-empty, trimmed
  - `effectiveDates` must be non-empty
  - each date must match `yyyyMMdd` and be a valid calendar date
  - dedupe dates per key (reject or normalize; pick one policy and be consistent)
- Enforce a safety guardrail:
  - reject if total chunks > configured max (prevents accidental “million chunk” jobs)

Big-tech standard: never trust clients to be reasonable. Guardrails are mandatory.

**Response**

HTTP `202 Accepted`

json { "jobId": "J20260102_000123", "status": "SUBMITTED" }

### 4.2 Get job status

`GET /jobs/{jobId}`

**Response (IN_PROGRESS)**

json { "jobId": "J20260102_000123", "status": "IN_PROGRESS", "total": 4, "pending": 1, "running": 1, "done": 2, "failed": 0, "filesGenerated": 2, "filesReused": 0, "s3BasePath": "s3:/// /", "errorMessage": null }


**Response (COMPLETED)**

json { "jobId": "J20260102_000123", "status": "COMPLETED", "total": 4, "pending": 0, "running": 0, "done": 4, "failed": 0, "filesGenerated": 3, "filesReused": 1, "s3BasePath": "s3:/// /", "errorMessage": null }


**Response (FAILED)**

json { "jobId": "J20260102_000123", "status": "FAILED", "total": 4, "pending": 0, "running": 0, "done": 3, "failed": 1, "filesGenerated": 3, "filesReused": 0, "s3BasePath": "s3:/// /", "errorMessage": "Chunk failed after retries: key=ABC date=2025-03-15" }


---

## 5. Queue contract

### 5.1 Queue name

- Work queue: `job.chunk.work`
- Parking queue (DLQ-lite, recommended): `job.chunk.parking`

### 5.2 Message payload (one message = one chunk)
json { "jobId": "J20260102_000123", "key": "ABC", "effectiveDate": "20250215" }


### 5.3 Delivery guarantee (what you can and cannot assume)

You can assume:

- A message is delivered to only one consumer at a time.

You cannot assume:

- “Exactly once” processing.

Redelivery after failure is expected. The system must be idempotent.

## 6. S3 output layout (your required structure)

### Base path (constant for all jobs)

- Bucket and base path are constant across all outputs: `s3://<bucket>/<basePath>/`

### Deterministic key template

`<basePath>/<YYYY>/<MM>/<DD>/<KEY>_<YYYYMMDD>.csv`

### Examples (basePath = `exports/`)

- `exports/2025/02/15/ABC_20250215.csv`
- `exports/2025/02/15/XYZ_20250215.csv`
- `exports/2025/03/15/ABC_20250315.csv`

This layout is not negotiable because it is the foundation of:

- deduplication
- file reuse
- stable downstream access

---

## 7. Database schema (tables + columns + why they exist)

### 7.1 `job`

One row per job.

| column | type | why it exists |
|---|---|---|
| `job_id` (PK) | `varchar` | External identifier used by clients and workers |
| `status` | `varchar` | `SUBMITTED` / `IN_PROGRESS` / `COMPLETED` / `FAILED` / `CANCELLED` |
| `request_json` | `jsonb` | Audit/debug; needed to reproduce behavior |
| `created_at` | `timestamptz` | Audit |
| `updated_at` | `timestamptz` | Audit |
| `s3_base_path` | `text` | Returned in status response; keeps environment-config visible |
| `error_message` | `text` | Human-readable summary on `FAILED` |

Indexes:

- (`status`)
- (`created_at`)

---

### 7.2 `job_chunk`

One row per (`jobId`, `key`, `effectiveDate`).

| column | type | why it exists |
|---|---|---|
| `job_id` | `varchar` | Groups chunks by job |
| `chunk_key` | `varchar` | Deterministic unique id: `key=<K>:date=<YYYYMMDD>` |
| `key` | `varchar` | Partition dimension for output naming |
| `effective_date` | `date` | The date the export is for |
| `status` | `varchar` | `PENDING` / `RUNNING` / `DONE` / `FAILED` |
| `attempts` | `int` | Required for controlled retries |
| `locked_at` | `timestamptz` | Lease timestamp for crash recovery |
| `lock_owner` | `varchar` | Debugging: which worker owned it |
| `started_at` | `timestamptz` | First time `RUNNING` happened |
| `completed_at` | `timestamptz` | When `DONE`/`FAILED` |
| `s3_object_key` | `text` | Actual output key (relative) |
| `row_count` | `int` | Optional but useful for verification |
| `reused` | `boolean` | Indicates whether we skipped DB and reused existing file |
| `error_message` | `text` | Last error for failures |

Constraints / indexes:

- PK (recommended): (`job_id`, `chunk_key`)
- index: (`job_id`, `status`)
- index: (`key`, `effective_date`) (optional)

Chunk statuses (only these four):

- `PENDING`: created, not started
- `RUNNING`: claimed by a worker
- `DONE`: output available
- `FAILED`: permanently failed after retries

---

### 7.3 `file_cache` (optional but recommended for reuse)

This table tracks generated files so that the system can decide whether a file can be reused or must be regenerated.

| column | type | purpose |
|---|---|---|
| `key` | `varchar` | Part of uniqueness |
| `effective_date` | `date` | Part of uniqueness |
| `s3_object_key` | `text` | Deterministic S3 object path |
| `row_count` | `int` | Number of rows written |
| `created_at` | `timestamptz` | When the file was first generated |
| `last_generated_at` | `timestamptz` | When the file was last regenerated |

Unique constraint:

- (`key`, `effective_date`)

The `last_generated_at` column is used to support time-based regeneration logic.

If a file is regenerated, the same deterministic S3 object key is overwritten and `last_generated_at` is updated.

Critical note: If you don’t want reuse now, skip this table and skip reuse logic. But don’t partially implement reuse.

The regeneration window (`reuseWindowDays`) must be configurable via application configuration (for example, YAML) and must not be hardcoded.

---

## 8. Reuse vs Regenerate Policy

File reuse is conditional and governed by a time-based regeneration window.

Let:

- `effectiveDate` be the date associated with the chunk
- `currentDate` be the current date evaluated in a single consistent timezone (recommended: UTC)
- `reuseWindowDays` be a configurable value (default: `7`)

Rules:

- If `effectiveDate >= currentDate - reuseWindowDays`  
  → the file must be regenerated, even if it already exists.
- If `effectiveDate < currentDate - reuseWindowDays`  
  → the file may be reused if an existing file is found.

This policy ensures that recent data is always freshly generated, while older data benefits from reuse.

---

## 9. Export DB function contract (required behavior)

We will create a dedicated export function/procedure that:

- disables pagination
- returns all rows (10k–30k typical per chunk)
- returns a row-set, not a JSON aggregation

Recommended contract (conceptual):

- input: (`key` `text`, `effective_date` `date`)
- output: `TABLE(...)` row set

Why row-set:

- allows streaming to CSV
- avoids DB JSON build overhead
- avoids memory spikes

---

## 10. Worker processing: exact algorithm (idempotent + crash-safe)

### 10.1 Important: message consumption semantics

We use transactional consumption:

- message is removed only after successful processing completes
- on exception/crash → message redelivered

This is required to avoid “lost work”.

### 10.2 Steps per message

Input message: (`jobId`, `key`, `effectiveDate`)

**Step 0 – Job guard**  
If the job status is `FAILED` or `CANCELLED`, acknowledge the message and return without processing.

**Step 1 – Claim chunk (idempotency + lease)**
sql UPDATE job_chunk SET status='RUNNING', locked_at=now(), attempts=attempts+1, lock_owner=:workerId, started_at=coalesce(started_at, now()) WHERE job_id=:jobId AND chunk_key=:chunkKey AND ;

If no row is updated, the chunk is already owned or completed; acknowledge the message and return.

**Step 2 – Decide reuse eligibility**  
Before checking cache or object storage, determine whether reuse is allowed.

- If the `effectiveDate` falls within the configured regeneration window, the file must be regenerated.
- Otherwise, reuse may be attempted.

This decision must be made before checking `file_cache` or S3.

**Step 3 – Reuse or generate**

- If reuse is allowed and a cache entry exists, mark the chunk as `DONE` with `reused=true`.
- Otherwise, invoke the export DB function, stream results to CSV, and upload to the deterministic S3 path.

**Step 4 – Update file cache**  
After successful generation, update the cache entry. If a record already exists, it must be updated to reflect the latest generation time and metadata.

**Step 5 – Mark chunk DONE**
sql UPDATE job_chunk SET status='DONE', completed_at=now(), s3_object_key=:s3Key, row_count=:rowCount, reused=:reused WHERE job_id=:jobId AND chunk_key=:chunkKey;

**Step 6 – Failure handling**

- Retry processing up to the configured maximum attempts.
- After retries are exhausted, mark the chunk as `FAILED`.

If any chunk is marked `FAILED`, the overall job is considered failed.

---

## 11. Failure handling (what happens when things break)

### 11.1 Retriable failures

Examples:

- transient DB error
- temporary network issue to S3
- worker restart

Policy:

- allow up to `MAX_ATTEMPTS` (e.g., `5`)

On exception:

- update `error_message`
- if `attempts < MAX_ATTEMPTS` → throw exception (message redelivered)
- else mark `FAILED` and optionally publish to parking queue

### 11.2 Stuck RUNNING recovery (“leaseExpired”)

Problem:

- worker can die after setting status `RUNNING`

Solution:

- `locked_at` acts as a lease
- if `RUNNING` and `locked_at` older than lease duration → another worker can reclaim the chunk

Lease duration must be >> worst-case chunk runtime.

---

## 12. Job completion rules

### 12.1 Job status is derived from chunk rows

Query:
sql SELECT count(*) total, sum(case when status='PENDING' then 1 else 0 end) pending, sum(case when status='RUNNING' then 1 else 0 end) running, sum(case when status='DONE' then 1 else 0 end) done, sum(case when status='FAILED' then 1 else 0 end) failed, sum(case when reused=true then 1 else 0 end) reused_count FROM job_chunk WHERE job_id=:jobId;

Rules:

- if `failed > 0` → job `FAILED`
- else if `done == total` → job `COMPLETED`
- else → job `IN_PROGRESS`

### 12.2 When do we update `job.status`?

Two options:

- compute on every `GET /jobs/{jobId}` (simple)
- periodic finalizer (more consistent)

We can start with “compute on GET” and add finalizer later.

---

## 13. Threads + containers + queue: correctness guarantee (your concern)

You can run:

- multiple ECS tasks (containers)
- each task with multiple listener threads

All threads across all containers are competing consumers of the same queue.

ActiveMQ queue guarantees:

- a message is delivered to only one consumer at a time
- if consumer fails before commit/ack, message will be redelivered later

We guarantee correctness via:

- DB claim step prevents two workers from processing same chunk concurrently
- lease reclaim handles crashes
- deterministic S3 key + unique cache prevents duplicate outputs

So yes: threads within a container and across containers work together without discrepancies when you follow this pattern.

---

## 14. Critical implementation decisions (do not ignore)

These will make or break production stability:

1. Streaming output
    - Never load 30k rows into memory and then write.
    - Stream from JDBC to CSV.
2. DB connection pool sizing
    - If you run N concurrent consumers in one container, Hikari pool must support it.
    - If pool < concurrency, threads block and throughput collapses.
3. Retry policy
    - Infinite retries are unacceptable.
    - After `MAX_ATTEMPTS`, chunk becomes `FAILED`.
4. Deterministic S3 keys
    - If you allow random file names, you will create duplicates and cannot reuse.
5. Guardrails on job size
    - Must cap total chunks per request to protect the system.