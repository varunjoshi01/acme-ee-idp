-- 08_cost_and_accuracy.sql
-- Is it right, and what did it cost? Measure both before trusting the pipeline.

USE ROLE ACME_ENGINEER;
USE WAREHOUSE ACME_EE_WH;
USE SCHEMA ACME_EE.RAW;

-- The right answers for every test document (data/labels.csv). make_sample_docs.py
-- writes them from the same records it builds the documents from.
CREATE STAGE IF NOT EXISTS REFERENCE_FILES ENCRYPTION = (TYPE = 'SNOWFLAKE_SSE');
-- PUT 'file://data/labels.csv' @ACME_EE.RAW.REFERENCE_FILES AUTO_COMPRESS = FALSE OVERWRITE = TRUE;

CREATE OR REPLACE TABLE LABELS (
  file_name STRING, source_format STRING, provenance STRING,
  municipality STRING, parcel_id STRING, address STRING, owner_name STRING, dwelling_style STRING,
  year_built STRING, year_remodeled STRING, stories STRING, living_area_sqft STRING, total_rooms STRING,
  bedrooms STRING, full_baths STRING, half_baths STRING, heating_fuel STRING, heating_system STRING,
  ac_type STRING, basement_type STRING, roof_structure STRING, last_sale_date STRING,
  last_sale_price STRING, assessed_value STRING);

COPY INTO LABELS FROM @REFERENCE_FILES/labels.csv
  FILE_FORMAT = (TYPE = CSV SKIP_HEADER = 1 FIELD_OPTIONALLY_ENCLOSED_BY = '"' EMPTY_FIELD_AS_NULL = TRUE)
  FORCE = TRUE;

USE SCHEMA ACME_EE.CORE;

-- Field-by-field: what the model returned vs the truth. Compares the raw model
-- output (not the cleaned table), so this measures AI_EXTRACT itself.
CREATE OR REPLACE VIEW EXTRACTION_ACCURACY AS
WITH truth AS (
  SELECT file_name, source_format, field_name, expected
  FROM ACME_EE.RAW.LABELS
  UNPIVOT INCLUDE NULLS (expected FOR field_name IN (
    municipality, parcel_id, address, owner_name, dwelling_style, year_built, year_remodeled,
    stories, living_area_sqft, total_rooms, bedrooms, full_baths, half_baths, heating_fuel,
    heating_system, ac_type, basement_type, roof_structure, last_sale_date, last_sale_price,
    assessed_value))
), j AS (
  SELECT t.file_name, t.source_format, LOWER(t.field_name) AS field_name,
         t.expected, g.extracted_value, g.score
  FROM truth t
  JOIN FIELD_SCORES g ON g.file_name = t.file_name AND LOWER(g.field_name) = LOWER(t.field_name)
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

-- Accuracy by document format.
SELECT source_format, COUNT(*) AS fields, COUNT_IF(is_correct) AS correct,
       ROUND(100 * COUNT_IF(is_correct) / COUNT(*), 1) AS pct_correct
FROM EXTRACTION_ACCURACY
GROUP BY ROLLUP (source_format) ORDER BY source_format NULLS LAST;

-- Does the confidence score mean anything? This is where the 0.8 review threshold came from.
SELECT CASE WHEN score < 0.5 THEN 'a: <0.5'   WHEN score < 0.6 THEN 'b: 0.5-0.6'
            WHEN score < 0.7 THEN 'c: 0.6-0.7' WHEN score < 0.8 THEN 'd: 0.7-0.8'
            WHEN score < 0.9 THEN 'e: 0.8-0.9' ELSE 'f: >=0.9' END AS score_band,
       COUNT(*) AS fields, COUNT_IF(NOT is_correct) AS wrong,
       ROUND(100 * COUNT_IF(is_correct) / COUNT(*), 1) AS pct_correct
FROM EXTRACTION_ACCURACY GROUP BY 1 ORDER BY 1;

-- Errors the review queue would miss.
SELECT a.* FROM EXTRACTION_ACCURACY a
WHERE NOT a.is_correct
  AND NOT EXISTS (SELECT 1 FROM REVIEW_QUEUE q
                  WHERE q.file_name = a.file_name AND q.field_name = a.field_name);

-- Cost. These views lag by a few hours. (CORTEX_FUNCTIONS_QUERY_USAGE_HISTORY
-- stayed empty on our account; the data was in the views below.)
USE ROLE ACCOUNTADMIN;
SELECT function_name, model_name, COUNT(*) AS queries, ROUND(SUM(credits), 4) AS credits
FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_AI_FUNCTIONS_USAGE_HISTORY
WHERE ARRAY_CONTAINS('ACME_ENGINEER'::VARIANT, role_names)
GROUP BY 1, 2 ORDER BY credits DESC;

SELECT function_name, model_name, SUM(page_count) AS pages, ROUND(SUM(credits_used), 4) AS credits
FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_DOCUMENT_PROCESSING_USAGE_HISTORY
GROUP BY 1, 2;

SELECT agent_name, COUNT(*) AS questions, ROUND(SUM(token_credits), 4) AS credits
FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_AGENT_USAGE_HISTORY
WHERE agent_database_name = 'ACME_EE'
GROUP BY 1;

-- Wall-clock time, available immediately.
SELECT CASE WHEN query_text ILIKE '%DATA_AGENT_RUN%' THEN 'Agent question'
            WHEN query_text ILIKE '%AI_COMPLETE%'    THEN 'AI_COMPLETE'
            WHEN query_text ILIKE '%AI_EXTRACT(text%' THEN 'AI_EXTRACT from parsed text'
            WHEN query_text ILIKE '%AI_EXTRACT(%'    THEN 'AI_EXTRACT from file'
            WHEN query_text ILIKE '%AI_PARSE_DOCUMENT%' THEN 'AI_PARSE_DOCUMENT' END AS step,
       COUNT(*) AS runs, ROUND(MAX(total_elapsed_time) / 1000, 1) AS max_seconds, MAX(rows_produced) AS max_rows
FROM TABLE(ACME_EE.INFORMATION_SCHEMA.QUERY_HISTORY(RESULT_LIMIT => 10000))
WHERE execution_status = 'SUCCESS' AND query_type NOT ILIKE 'CREATE%'
  AND (query_text ILIKE '%AI_PARSE_DOCUMENT(%' OR query_text ILIKE '%AI_EXTRACT(%'
       OR query_text ILIKE '%AI_COMPLETE(%' OR query_text ILIKE '%DATA_AGENT_RUN(%')
  AND query_text NOT ILIKE '%QUERY_HISTORY%'
GROUP BY 1 ORDER BY 1;
