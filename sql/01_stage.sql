-- 01_stage.sql
-- Where documents land, plus a manifest of where each one came from.
-- In production the files arrive from a fetch job (External Access Integration +
-- Python procedure, or an external crawler writing to S3/Azure behind an
-- external stage). For the demo we upload them with PUT.

USE ROLE ACME_ENGINEER;
USE WAREHOUSE ACME_EE_WH;
USE SCHEMA ACME_EE.RAW;

CREATE STAGE IF NOT EXISTS ASSESSOR_DOCS
  ENCRYPTION = (TYPE = 'SNOWFLAKE_SSE')   -- server-side encryption, required for AI_PARSE_DOCUMENT/AI_EXTRACT
  DIRECTORY = (ENABLE = TRUE)
  COMMENT = 'Municipal property records as published: HTML, PDF, scans';

-- From SnowSQL / Snowflake CLI / Cortex Code, run from the repo root:
-- PUT 'file://data/docs/*' @ACME_EE.RAW.ASSESSOR_DOCS AUTO_COMPRESS = FALSE OVERWRITE = TRUE;

-- Internal stages don't auto-refresh their directory table. Without this the
-- directory (and the stream below) shows zero files even though PUT succeeded.
ALTER STAGE ASSESSOR_DOCS REFRESH;

-- New or changed files show up here; the nightly task reads from it.
CREATE STREAM IF NOT EXISTS NEW_DOCS_STREAM ON STAGE ASSESSOR_DOCS;

-- Ingestion manifest. The fetch job knows which town it pulled a file from,
-- so record it here instead of asking the model. (A Greenfield scan's header
-- had no state on it and AI_EXTRACT returned nothing for municipality.)
CREATE TABLE IF NOT EXISTS DOC_SOURCES (
    file_name    STRING,
    municipality STRING,
    source_type  STRING,
    fetched_at   TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP()
);

MERGE INTO DOC_SOURCES t
USING (
  SELECT column1 AS file_name, column2 AS municipality,
         SPLIT_PART(SPLIT_PART(column1, '_', -1), '.', 1) AS source_type
  FROM VALUES
    ('01_springfield_html.html','Springfield, MA'), ('02_stamford_vision.pdf','Stamford, CT'),
    ('03_springfield_html.html','Springfield, MA'), ('04_chicopee_html.html','Chicopee, MA'),
    ('05_holyoke_html.html','Holyoke, MA'),         ('06_stamford_vision.pdf','Stamford, CT'),
    ('07_norwalk_vision.pdf','Norwalk, CT'),        ('08_new_britain_vision.pdf','New Britain, CT'),
    ('09_worcester_town.pdf','Worcester, MA'),      ('10_fitchburg_town.pdf','Fitchburg, MA'),
    ('11_leominster_town.pdf','Leominster, MA'),    ('12_gardner_town.pdf','Gardner, MA'),
    ('13_pittsfield_scan.png','Pittsfield, MA'),    ('14_north_adams_scan.png','North Adams, MA'),
    ('15_greenfield_scan.png','Greenfield, MA'),    ('16_athol_scan.png','Athol, MA')
) s
ON t.file_name = s.file_name
WHEN NOT MATCHED THEN INSERT (file_name, municipality, source_type)
                      VALUES (s.file_name, s.municipality, s.source_type);

SELECT COUNT(*) AS files_on_stage FROM DIRECTORY(@ASSESSOR_DOCS);
