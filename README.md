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

2. Core concepts (strict definitions)
2.1 Job
A job = one API submission.
A job contains N chunks derived from the request body.
2.2 Chunk
A chunk = one (key, effectiveDate) pair.
One chunk produces exactly:
•	One DB call
•	One output CSV file at a deterministic S3 path
2.3 Deterministic output path
Deterministic file paths are mandatory to prevent duplicates and enable reuse.
File naming rule:
•	File name: <KEY>_<YYYYMMDD>.csv
•	Folder rule under base path: YYYY/MM/DD/
Example:
•	base path: s3://<bucket>/<basePath>/
•	key = ABC, date = 20250215
•	output key:
s3://<bucket>/<basePath>/2025/02/15/ABC_20250215.csv
________________________________________
3. Components
3.1 api-svc (Spring Boot)
Responsibilities:
•	Validate request
•	Create a job record
•	Expand request into chunk rows
•	Publish one queue message per chunk
•	Provide job status endpoint
Non-responsibilities:
•	Does NOT call the export DB function
•	Does NOT generate files
3.2 wrk-svc (Spring Boot)
Responsibilities:
•	Consume queue messages
•	Ensure idempotency using DB claim+lease
•	Optionally reuse existing files
•	Call export DB function (non-paginated)
•	Stream results into CSV
•	Write file to deterministic S3 location
•	Mark chunk DONE/FAILED in DB
3.3 mq (ActiveMQ queue)
•	Queue distributes chunks to competing consumers.
•	A message is delivered to only one consumer at a time.
•	Messages can be redelivered after failures (normal behavior).
3.4 pg (Postgres)
•	System of record for job and chunk state.
•	Holds chunk statuses and retry counts.
•	(Optional) Holds file reuse cache.
3.5 s3 (Object storage)
•	Stores output CSV files at deterministic paths.
