-- =========================================================
-- Export Job (parent)
-- =========================================================
create table if not exists export_job (
                                          job_id              uuid primary key,
                                          job_key             text not null,
                                          job_type            text not null,
                                          status              text not null,

                                          requested_by        text null,
                                          requested_at        timestamptz not null default now(),
    started_at          timestamptz null,
    completed_at        timestamptz null,

    effective_date      date null,
    parameters_json     jsonb not null,

    total_chunks        int null,
    completed_chunks    int not null default 0,

    output_location     text null,
    error_code          text null,
    error_message       text null,

    lease_owner         text null,
    lease_until         timestamptz null,

    constraint uq_export_job_key unique (job_key)
    );

create index if not exists idx_export_job_status
    on export_job(status);

create index if not exists idx_export_job_lease
    on export_job(status, lease_until);

-- =========================================================
-- Export Job Chunk
-- =========================================================
create table if not exists export_job_chunk (
                                                chunk_id        uuid primary key,
                                                job_id          uuid not null,
                                                chunk_no        int not null,
                                                status          text not null,
                                                attempt_count   int not null default 0,

                                                started_at      timestamptz null,
                                                completed_at    timestamptz null,

                                                output_location text null,
                                                error_message   text null,

                                                constraint fk_chunk_job
                                                foreign key (job_id)
    references export_job(job_id)
    on delete cascade,

    constraint uq_job_chunk
    unique (job_id, chunk_no)
    );

create index if not exists idx_export_chunk_job
    on export_job_chunk(job_id);

create index if not exists idx_export_chunk_status
    on export_job_chunk(status);

-- =========================================================
-- Export Job Chunk Attempt (for retries & diagnostics)
-- =========================================================
create table if not exists export_job_chunk_attempt (
                                                        attempt_id      uuid primary key,
                                                        chunk_id        uuid not null,
                                                        attempt_no      int not null,
                                                        status          text not null,

                                                        started_at      timestamptz not null default now(),
    completed_at    timestamptz null,
    error_message   text null,

    constraint fk_attempt_chunk
    foreign key (chunk_id)
    references export_job_chunk(chunk_id)
    on delete cascade,

    constraint uq_chunk_attempt
    unique (chunk_id, attempt_no)
    );

create index if not exists idx_chunk_attempt_chunk
    on export_job_chunk_attempt(chunk_id);
