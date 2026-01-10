# 📦 Data Distribution Service – Full Design (Authoritative, DB-only DLQ, Simplified S3 Paths)

This document is the **single source of truth** for the Data Distribution Service design.  
It reflects all decisions agreed so far, with **simplified S3 path handling** and **DB-only DLQ**.

> **Design goals:** deterministic execution, crash safety, horizontal scalability, observability, and operational simplicity.

---

## 1. System Overview

Data Distribution Service is an asynchronous export platform that:
- Accepts a batch of inputs in one job
- Processes each input independently (one input → one output file)
- Applies **retry with exponential backoff** on failures
- Uses **DB-only DLQ** for terminal failures
- Applies **fail-fast job semantics**: *any input in DLQ ⇒ job FAILED*
- Supports configurable **file reuse** (flag + days)

The **database (Postgres)** is the source of truth and the primary work coordination mechanism.

---

## 2. High-Level Architecture

```
Client
  |
  v
[distribution-api]  (REST)
  |
  v
PostgreSQL  (truth + coordination + recovery)
  |
  v
[distribution-worker]  (poll + claim + execute)
  |
  +----> Amazon S3 (job-scoped output files)
```

**Key principles**
- Workers and API are **stateless**
- All coordination is done via **DB leasing**
- No message broker is required

---

## 3. Maven Modules & Responsibilities

Repository root:
```
data-distribution-service
 ├─ distribution-core
 ├─ distribution-api
 └─ distribution-worker
```

### 3.1 distribution-core
Shared foundation used by API and Worker.
- Domain enums
- JPA entities
- Repositories
- State transition rules
- Shared exceptions/constants

### 3.2 distribution-api
Spring Boot app.
- `/jobs` submission
- `/jobs/{jobId}` status
- Flyway migrations

### 3.3 distribution-worker
Spring Boot app.
- DB polling & atomic claiming
- Input processing
- Retry scheduling (`RETRY_WAIT` + `next_retry_at`)
- DB-only DLQ handling
- Fast-path job completion attempt
- Finalizer job

---

## 4. API Contract

### 4.1 POST /jobs

**Request**
```json
{
  "inputs": [
    { "indexKey": "ABC", "effectiveDate": 20240202, "asofindicator": "CLS" },
    { "indexKey": "DEF", "effectiveDate": 20230506, "asofindicator": "ADJCLS" }
  ]
}
```

**Response**
```json
{ "jobId": "J20260110_000777", "status": "SUBMITTED" }
```

---

### 4.2 GET /jobs/{jobId}

**Purpose**: Poll job state and retrieve output file paths.

**Response (COMPLETED example)**
```json
{
  "jobId": "J20260110_000777",
  "status": "COMPLETED",
  "total": 2,
  "pending": 0,
  "running": 0,
  "done": 2,
  "failed": 0,
  "filesGenerated": 1,
  "filesReused": 1,
  "errorMessage": null,
  "dataContent": [
    {
      "indexKey": "ABC",
      "effectiveDate": 20240202,
      "asofindicator": "CLS",
      "s3Path": "s3://bucket/exports/2026/01/10/J20260110_000777/ABC_20240202_CLS.csv"
    },
    {
      "indexKey": "DEF",
      "effectiveDate": 20230506,
      "asofindicator": "ADJCLS",
      "s3Path": "s3://bucket/exports/2025/12/20/J20251220_000123/DEF_20230506_ADJCLS.csv"
    }
  ]
}
```

Notes:
- **No `s3BasePath`** is returned
- Each `dataContent[].s3Path` is an **absolute S3 location**
- Reused files may point to **previous job folders**

---

## 5. Database Schema

### 5.1 export_job
```sql
create table export_job (
  job_id uuid primary key,
  job_key text not null unique,
  status text not null,
  requested_at timestamptz default now(),
  started_at timestamptz,
  completed_at timestamptz,
  total_inputs int not null,
  error_message text
);
```

### 5.2 export_job_input
```sql
create table export_job_input (
  input_id uuid primary key,
  job_id uuid not null references export_job(job_id),
  index_key text not null,
  effective_date int not null,
  asof_indicator text not null,
  status text not null, -- PENDING, RUNNING, SUCCEEDED, RETRY_WAIT, DLQ
  attempt_count int default 0,
  next_retry_at timestamptz,
  s3_path text,
  is_reused boolean default false,
  error_message text,
  lease_owner text,
  lease_until timestamptz,
  unique(job_id, index_key, effective_date, asof_indicator)
);
```

### 5.3 export_artifact (reuse registry)
```sql
create table export_artifact (
  artifact_id uuid primary key,
  index_key text not null,
  effective_date int not null,
  asof_indicator text not null,
  s3_path text not null,
  source_job_id uuid not null,
  generated_at timestamptz default now(),
  unique(index_key, effective_date, asof_indicator)
);
```

Purpose:
- Tracks **latest usable file path** for reuse
- Points to **actual job folder path** where file exists

### 5.4 Indexes
```sql
-- export_job: for finalizer scans and status-based filtering
create index if not exists ix_export_job_status on export_job(status);
create index if not exists ix_export_job_requested_at on export_job(requested_at);

-- export_job_input: for polling and leasing
create index if not exists ix_input_job_id on export_job_input(job_id);
create index if not exists ix_input_status on export_job_input(status);

-- critical for polling eligibility (PENDING / RETRY_WAIT due) + lease expiry
create index if not exists ix_input_polling
  on export_job_input(status, next_retry_at, lease_until);

-- optional but helpful when you frequently filter by lease_owner
create index if not exists ix_input_lease_owner
  on export_job_input(lease_owner);

-- reuse registry lookup must be fast
create unique index if not exists ux_artifact_key
  on export_artifact(index_key, effective_date, asof_indicator);

-- optional: useful if you want to find newest artifacts
create index if not exists ix_artifact_generated_at
  on export_artifact(generated_at desc);
```

---

## 6. File Reuse Logic

### 6.1 Configuration
```yaml
file:
  reuse:
    enabled: true
    days: 7
```

### 6.2 Decision flow
```
if reuse.enabled == false:
    generate
else if artifact not found:
    generate
else if effectiveDate > today - reuse.days:
    generate
else:
    reuse
```

### 6.3 Behavior
- **Generate**:
    - Write file under current job folder
    - Update `export_artifact` to point to this new path
    - Mark input `SUCCEEDED`, `is_reused=false`

- **Reuse**:
    - Read path from `export_artifact`
    - Mark input `SUCCEEDED`, `is_reused=true`
    - No S3 write

---

## 7. Worker Execution Flow

```
PENDING
 → RUNNING
   → SUCCEEDED (generated)
   → SUCCEEDED (reused)
   → FAILURE
        → RETRY_WAIT
        → RUNNING (retry)
        → …
        → DLQ
```

- `RETRY_WAIT` = scheduled retry
- `DLQ` = terminal failure in DB

---

## 8. Job Completion

### 8.1 Fast-path completion (worker)
```sql
update export_job
set status = 'COMPLETED', completed_at = now()
where job_id = :jobId
  and not exists (
    select 1 from export_job_input
    where job_id = :jobId
      and status in ('PENDING','RUNNING','RETRY_WAIT')
  )
  and not exists (
    select 1 from export_job_input
    where job_id = :jobId and status = 'DLQ'
  );
```

### 8.2 Finalizer
- Periodic reconciliation
- Ensures correctness under crashes or races

---

## 9. Retry Policy

- Per-input retry
- Exponential backoff (+ jitter recommended)
- `RETRY_WAIT` controls eligibility
- Retries do **not** fail job

---

## 10. DB-only DLQ

- `export_job_input.status = 'DLQ'`
- Any DLQ input ⇒ job FAILED
- Re-drive possible by resetting status

---

## 11. Main SQL Queries

Notes:

- Treat export_job_input as the unit of work (“chunk”).
- Claim must be atomic; always check affected row count.
- Keep claim/update queries in short transactions.

### 1) Create Job
```sql
insert into export_job (
  job_id, job_key, status, requested_at, total_inputs
) values (
  :jobId, :jobKey, 'SUBMITTED', now(), :totalInputs
);
```

### 2) Insert Job Inputs (Chunks)
```sql
insert into export_job_input (
  input_id, job_id, index_key, effective_date, asof_indicator,
  status, attempt_count, is_reused
) values (
  :inputId, :jobId, :indexKey, :effectiveDate, :asofIndicator,
  'PENDING', 0, false
);
```

### 3) Candidate Selection (Polling) — IDs Only
Select a small batch of eligible input IDs:
```sql
select i.input_id
from export_job_input i
join export_job j on j.job_id = i.job_id
where j.status in ('SUBMITTED','RUNNING')
  and (
       i.status = 'PENDING'
       or (i.status = 'RETRY_WAIT' and i.next_retry_at <= now())
  )
  and (i.lease_until is null or i.lease_until < now())
order by j.requested_at asc, i.input_id asc
limit :batchSize;
```

### 4) Atomic Claim (Lease + RUNNING)
This is the safety gate. Only one worker will update 1 row.
```sql
update export_job_input
set status = 'RUNNING',
    lease_owner = :workerId,
    lease_until = now() + (:leaseSeconds || ' seconds')::interval
where input_id = :inputId
  and (
       status = 'PENDING'
       or (status = 'RETRY_WAIT' and next_retry_at <= now())
  )
  and (lease_until is null or lease_until < now());
```

### 5) Mark Input Success (Generated)
```sql
update export_job_input
set status = 'SUCCEEDED',
    s3_path = :s3Path,
    is_reused = false,
    error_message = null,
    lease_until = null
where input_id = :inputId
  and lease_owner = :workerId;
```

### 6) Mark Input Success (Reused)
```sql
update export_job_input
set status = 'SUCCEEDED',
    s3_path = :s3Path,
    is_reused = true,
    error_message = null,
    lease_until = null
where input_id = :inputId
  and lease_owner = :workerId;
```

### 7) Schedule Retry (RETRY_WAIT)
Use when error is retryable and attempts remain.
```sql
update export_job_input
set status = 'RETRY_WAIT',
    attempt_count = attempt_count + 1,
    next_retry_at = :nextRetryAt,
    error_message = :errorMessage,
    lease_until = null
where input_id = :inputId
  and lease_owner = :workerId;
```

### 8) Move Input to DLQ (DB-only terminal failure)
Use when retries exhausted or error is non-recoverable.
```sql
update export_job_input
set status = 'DLQ',
    attempt_count = attempt_count + 1,
    error_message = :errorMessage,
    lease_until = null
where input_id = :inputId
  and lease_owner = :workerId;
```

### 9) Fail Job Immediately (Fail-fast rule)
Run after marking any input as DLQ.
```sql
update export_job
set status = 'FAILED',
    completed_at = now(),
    error_message = :jobError
where job_id = :jobId
  and status not in ('FAILED','CANCELLED');
```

### Reuse / Artifact Queries
### 10) Find Reusable Artifact (Lookup)
This returns the latest known usable path (which may be from a previous job folder).
```sql
select a.s3_path, a.source_job_id, a.generated_at
from export_artifact a
where a.index_key = :indexKey
  and a.effective_date = :effectiveDate
  and a.asof_indicator = :asofIndicator;
```
Reuse decision is done in code using:
- file.reuse.enabled
- file.reuse.days
- effectiveDate vs “today - reuseDays”


### 11) Upsert Artifact After Generation
When a file is newly generated (under current job folder), update the artifact registry.
Postgres UPSERT:
```sql
insert into export_artifact (
  artifact_id, index_key, effective_date, asof_indicator,
  s3_path, source_job_id, generated_at
) values (
  :artifactId, :indexKey, :effectiveDate, :asofIndicator,
  :s3Path, :jobId, now()
)
on conflict (index_key, effective_date, asof_indicator)
do update set
  s3_path = excluded.s3_path,
  source_job_id = excluded.source_job_id,
  generated_at = excluded.generated_at;
```

### Job Completion Queries
### 12) Worker Fast-path Completion Attempt
Worker tries to complete the job right after finishing an input.
```sql
update export_job
set status = 'COMPLETED',
    completed_at = now()
where job_id = :jobId
  and status in ('SUBMITTED','RUNNING')
  and not exists (
    select 1
    from export_job_input
    where job_id = :jobId
      and status in ('PENDING','RUNNING','RETRY_WAIT')
  )
  and not exists (
    select 1
    from export_job_input
    where job_id = :jobId
      and status = 'DLQ'
  );
```
✅ Treat as best-effort; finalizer remains authoritative.


### 13) Finalizer — Mark FAILED First
```sql
update export_job j
set status = 'FAILED',
    completed_at = now(),
    error_message = 'One or more inputs moved to DLQ'
where j.status in ('SUBMITTED','RUNNING')
  and exists (
    select 1
    from export_job_input i
    where i.job_id = j.job_id
      and i.status = 'DLQ'
  );
```

### 14) Finalizer — Mark COMPLETED
```sql
update export_job j
set status = 'COMPLETED',
    completed_at = now()
where j.status in ('SUBMITTED','RUNNING')
  and not exists (
    select 1
    from export_job_input i
    where i.job_id = j.job_id
      and i.status in ('PENDING','RUNNING','RETRY_WAIT')
  )
  and not exists (
    select 1
    from export_job_input i
    where i.job_id = j.job_id
      and i.status = 'DLQ'
  );
```

### Optional Operational Queries (Support)
### 15) Job Summary Counts (for /jobs/{jobId} response)
```sql
select
  count(*) as total,
  count(*) filter (where status = 'PENDING') as pending,
  count(*) filter (where status = 'RUNNING') as running,
  count(*) filter (where status = 'SUCCEEDED') as done,
  count(*) filter (where status = 'DLQ') as failed,
  count(*) filter (where status = 'SUCCEEDED' and is_reused = false) as files_generated,
  count(*) filter (where status = 'SUCCEEDED' and is_reused = true)  as files_reused
from export_job_input
where job_id = :jobId;
```



## 12. Configuration Knobs

- worker.poll.batchSize
- worker.lease.seconds
- retry.maxAttempts
- retry.baseDelayMs
- file.reuse.enabled
- file.reuse.days
- finalizer.intervalMs

---

## 13. Guarantees

✔ Simplified S3 paths  
✔ Deterministic reuse  
✔ DB-only DLQ  
✔ Retry-safe & crash-safe  
✔ ECS-ready scaling

---

**End of Document**

