-- 10_volume_test.sql
-- Same pipeline, 500 generated documents, separate tables so the demo data stays clean.
-- The 16-document set measures accuracy in detail; this run
-- measures throughput and cost at volume (and accuracy too, since the generator
-- writes labels for every file).
--
-- Upload first (from the repo root):
--   .venv/bin/python scripts/make_sample_docs.py --volume 500
--   PUT 'file://data/volume/*'        @ACME_EE.RAW.VOLUME_DOCS AUTO_COMPRESS = FALSE OVERWRITE = TRUE;
--   PUT 'file://data/volume_labels.csv' @ACME_EE.RAW.REFERENCE_FILES AUTO_COMPRESS = FALSE OVERWRITE = TRUE;

USE ROLE ACME_ENGINEER;
USE WAREHOUSE ACME_EE_WH;     -- X-Small; AI_EXTRACT gets no faster on bigger warehouses
USE SCHEMA ACME_EE.RAW;

CREATE STAGE IF NOT EXISTS VOLUME_DOCS
  ENCRYPTION = (TYPE = 'SNOWFLAKE_SSE') DIRECTORY = (ENABLE = TRUE);
ALTER STAGE VOLUME_DOCS REFRESH;

CREATE OR REPLACE TABLE VOLUME_PARSED (file_name STRING, content STRING, page_count NUMBER);
CREATE OR REPLACE TABLE VOLUME_EXTRACTIONS (file_name STRING, extracted VARIANT);

-- Step 1: parse every document.
ALTER SESSION SET QUERY_TAG = 'volume:parse';
INSERT INTO VOLUME_PARSED
SELECT relative_path, r:value:content::STRING, r:metadata:pageCount::NUMBER
FROM (SELECT relative_path,
             AI_PARSE_DOCUMENT(TO_FILE('@ACME_EE.RAW.VOLUME_DOCS', relative_path), {'mode': 'LAYOUT'}, TRUE) AS r
      FROM DIRECTORY(@VOLUME_DOCS));

-- Step 2a: digital documents, extracted straight from the file.
ALTER SESSION SET QUERY_TAG = 'volume:extract_file';
INSERT INTO VOLUME_EXTRACTIONS
SELECT relative_path,
       AI_EXTRACT(file => TO_FILE('@ACME_EE.RAW.VOLUME_DOCS', relative_path),
                  responseFormat => EXTRACTION_SCHEMA(), scores => TRUE)
FROM DIRECTORY(@VOLUME_DOCS)
WHERE relative_path NOT LIKE '%\\_scan.png' ESCAPE '\\';

-- Step 2b: scans, extracted from the parsed text.
ALTER SESSION SET QUERY_TAG = 'volume:extract_text';
INSERT INTO VOLUME_EXTRACTIONS
SELECT file_name, AI_EXTRACT(text => content, responseFormat => EXTRACTION_SCHEMA(), scores => TRUE)
FROM VOLUME_PARSED
WHERE file_name LIKE '%\\_scan.png' ESCAPE '\\';

ALTER SESSION UNSET QUERY_TAG;

-- Answer key for the generated set.
CREATE OR REPLACE TABLE VOLUME_LABELS LIKE LABELS;
COPY INTO VOLUME_LABELS FROM @REFERENCE_FILES/volume_labels.csv
  FILE_FORMAT = (TYPE = CSV SKIP_HEADER = 1 FIELD_OPTIONALLY_ENCLOSED_BY = '"' EMPTY_FIELD_AS_NULL = TRUE)
  FORCE = TRUE;

USE SCHEMA ACME_EE.CORE;

-- Same comparison rules as EXTRACTION_ACCURACY (08_cost_and_accuracy.sql).
CREATE OR REPLACE VIEW VOLUME_ACCURACY AS
WITH truth AS (
  SELECT file_name, source_format, LOWER(field_name) AS field_name, expected
  FROM ACME_EE.RAW.VOLUME_LABELS
  UNPIVOT INCLUDE NULLS (expected FOR field_name IN (
    municipality, parcel_id, address, owner_name, dwelling_style, year_built, year_remodeled,
    stories, living_area_sqft, total_rooms, bedrooms, full_baths, half_baths, heating_fuel,
    heating_system, ac_type, basement_type, roof_structure, last_sale_date, last_sale_price,
    assessed_value))
), got AS (
  SELECT e.file_name, LOWER(f.key) AS field_name,
         e.extracted:response[f.key]::STRING AS extracted_value, f.value:score::FLOAT AS score
  FROM ACME_EE.RAW.VOLUME_EXTRACTIONS e, LATERAL FLATTEN(input => e.extracted:scoring:scores) f
), j AS (
  SELECT t.*, g.extracted_value, g.score
  FROM truth t JOIN got g ON g.file_name = t.file_name AND g.field_name = t.field_name
)
SELECT j.*,
  CASE
    WHEN field_name IN ('year_built','year_remodeled','stories','living_area_sqft','total_rooms',
                        'bedrooms','full_baths','half_baths','last_sale_price','assessed_value')
      THEN EQUAL_NULL(CLEAN_NUMBER(extracted_value), CLEAN_NUMBER(expected))
    WHEN field_name = 'last_sale_date'
      THEN EQUAL_NULL(CLEAN_DATE(extracted_value), CLEAN_DATE(expected))
    WHEN field_name = 'heating_fuel'
      THEN EQUAL_NULL(NORMALIZE_FUEL(extracted_value), NORMALIZE_FUEL(expected))
    WHEN field_name = 'address'
      THEN UPPER(TRIM(SPLIT_PART(CLEAN_TEXT(extracted_value), ',', 1))) = UPPER(TRIM(SPLIT_PART(expected, ',', 1)))
    WHEN field_name IN ('dwelling_style','heating_system','ac_type','basement_type','roof_structure','municipality')
      THEN EQUAL_NULL(CLEAN_TEXT(extracted_value) IS NULL, CLEAN_TEXT(expected) IS NULL)
           AND (CLEAN_TEXT(expected) IS NULL
                OR CONTAINS(REGEXP_REPLACE(UPPER(extracted_value), '[^A-Z0-9]', ''),
                            REGEXP_REPLACE(UPPER(expected), '[^A-Z0-9]', '')))
    ELSE EQUAL_NULL(UPPER(CLEAN_TEXT(extracted_value)), UPPER(CLEAN_TEXT(expected)))
  END AS is_correct
FROM j;

-- Results
SELECT source_format, COUNT(DISTINCT file_name) AS docs, COUNT(*) AS fields,
       ROUND(100 * COUNT_IF(is_correct) / COUNT(*), 1) AS pct_correct,
       ROUND(100 * COUNT_IF(score >= 0.8 AND is_correct) / NULLIF(COUNT_IF(score >= 0.8), 0), 1) AS pct_correct_when_score_ge_0_8,
       ROUND(100 * COUNT_IF(score < 0.8) / COUNT(*), 1) AS pct_sent_to_review
FROM VOLUME_ACCURACY GROUP BY ROLLUP (source_format) ORDER BY source_format NULLS LAST;

-- Wall-clock time per step
SELECT query_tag, COUNT(*) AS statements, ROUND(SUM(total_elapsed_time) / 1000, 1) AS seconds,
       MAX(rows_produced) AS rows_written
FROM TABLE(ACME_EE.INFORMATION_SCHEMA.QUERY_HISTORY(RESULT_LIMIT => 10000))
WHERE query_tag LIKE 'volume:%' AND execution_status = 'SUCCESS' AND query_type = 'INSERT'
GROUP BY 1 ORDER BY 1;
