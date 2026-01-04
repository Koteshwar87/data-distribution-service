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