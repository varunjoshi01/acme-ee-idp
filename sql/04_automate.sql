-- 04_automate.sql
-- One procedure that runs the whole pipeline for whatever is new on the stage,
-- and a task that calls it when the stream says there's something to do.
-- Every step is "only files we haven't seen", so re-running is safe.

USE ROLE ACME_ENGINEER;
USE WAREHOUSE ACME_EE_WH;
USE SCHEMA ACME_EE.RAW;

-- Consuming the stream inside a DML statement moves its offset forward,
-- so this log doubles as the record of what each run picked up.
CREATE TABLE IF NOT EXISTS INGEST_LOG (
    run_id      STRING,
    file_name   STRING,
    logged_at   TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP()
);

CREATE OR REPLACE PROCEDURE RUN_PIPELINE()
RETURNS STRING
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
DECLARE
    run_id   STRING DEFAULT UUID_STRING();
    n_new    NUMBER DEFAULT 0;
    n_parsed NUMBER DEFAULT 0;
    n_extr   NUMBER DEFAULT 0;
BEGIN
    INSERT INTO ACME_EE.RAW.INGEST_LOG (run_id, file_name)
      SELECT :run_id, relative_path FROM ACME_EE.RAW.NEW_DOCS_STREAM
      WHERE METADATA$ACTION = 'INSERT';
    n_new := SQLROWCOUNT;

    INSERT INTO ACME_EE.RAW.PARSED_DOCS (file_name, content, page_count)
    SELECT relative_path, r:value:content::STRING, r:metadata:pageCount::NUMBER
    FROM (
      SELECT d.relative_path,
             AI_PARSE_DOCUMENT(TO_FILE('@ACME_EE.RAW.ASSESSOR_DOCS', d.relative_path), {'mode': 'LAYOUT'}, TRUE) AS r
      FROM DIRECTORY(@ACME_EE.RAW.ASSESSOR_DOCS) d
      WHERE d.relative_path NOT IN (SELECT file_name FROM ACME_EE.RAW.PARSED_DOCS)
    );
    n_parsed := SQLROWCOUNT;

    INSERT INTO ACME_EE.RAW.EXTRACTIONS (file_name, file_url, last_modified, extracted)
    SELECT d.relative_path, d.file_url, d.last_modified,
           AI_EXTRACT(file => TO_FILE('@ACME_EE.RAW.ASSESSOR_DOCS', d.relative_path),
                      responseFormat => ACME_EE.RAW.EXTRACTION_SCHEMA(), scores => TRUE)
    FROM DIRECTORY(@ACME_EE.RAW.ASSESSOR_DOCS) d
    JOIN ACME_EE.RAW.DOC_SOURCES s ON s.file_name = d.relative_path
    WHERE s.source_type <> 'scan'
      AND d.relative_path NOT IN (SELECT file_name FROM ACME_EE.RAW.EXTRACTIONS);
    n_extr := SQLROWCOUNT;

    INSERT INTO ACME_EE.RAW.EXTRACTIONS (file_name, file_url, last_modified, extracted)
    SELECT p.file_name, d.file_url, d.last_modified,
           AI_EXTRACT(text => p.content, responseFormat => ACME_EE.RAW.EXTRACTION_SCHEMA(), scores => TRUE)
    FROM ACME_EE.RAW.PARSED_DOCS p
    JOIN DIRECTORY(@ACME_EE.RAW.ASSESSOR_DOCS) d ON d.relative_path = p.file_name
    JOIN ACME_EE.RAW.DOC_SOURCES s ON s.file_name = p.file_name
    WHERE s.source_type = 'scan'
      AND p.file_name NOT IN (SELECT file_name FROM ACME_EE.RAW.EXTRACTIONS);
    n_extr := n_extr + SQLROWCOUNT;

    -- Same MERGE as 03_merge.sql; reviewed corrections are applied inside it.
    CALL ACME_EE.CORE.REFRESH_PROPERTIES();

    -- Add new low-confidence fields to the queue without touching reviewed ones.
    INSERT INTO ACME_EE.CORE.REVIEW_QUEUE
    SELECT f.file_name, p.municipality, p.parcel_id, f.field_name, f.extracted_value, f.score,
           'open', NULL, NULL, NULL
    FROM ACME_EE.CORE.FIELD_SCORES f
    LEFT JOIN ACME_EE.CORE.PROPERTY_ASSESSMENTS p ON p.source_file = f.file_name
    WHERE (f.score < 0.8
           OR (f.field_name IN ('heating_fuel','year_built','living_area_sqft')
               AND ACME_EE.CORE.CLEAN_TEXT(f.extracted_value) IS NULL))
      AND NOT EXISTS (SELECT 1 FROM ACME_EE.CORE.REVIEW_QUEUE q
                      WHERE q.file_name = f.file_name AND q.field_name = f.field_name);

    RETURN 'run ' || :run_id || ': ' || :n_new || ' new on stream, ' || :n_parsed || ' parsed, ' || :n_extr || ' extracted';
END;
$$;

-- Nightly, but only does work when files arrived. Serverless, so no warehouse to size.
CREATE OR REPLACE TASK NIGHTLY_PIPELINE
  SCHEDULE = 'USING CRON 0 2 * * * America/New_York'
  USER_TASK_MANAGED_INITIAL_WAREHOUSE_SIZE = 'XSMALL'
  WHEN SYSTEM$STREAM_HAS_DATA('ACME_EE.RAW.NEW_DOCS_STREAM')
AS
  CALL ACME_EE.RAW.RUN_PIPELINE();

-- Tasks are created suspended. For the demo, run it on demand:
--   EXECUTE TASK ACME_EE.RAW.NIGHTLY_PIPELINE;
-- In production:
--   ALTER TASK ACME_EE.RAW.NIGHTLY_PIPELINE RESUME;
