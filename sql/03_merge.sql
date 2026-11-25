-- 03_merge.sql
-- Turn raw AI_EXTRACT output into one clean, typed row per property.
-- MERGE on (municipality, parcel_id): parcel numbers repeat across towns,
-- so parcel_id alone is not a key. Re-running never creates duplicates.

USE ROLE ACME_ENGINEER;
USE WAREHOUSE ACME_EE_WH;
USE SCHEMA ACME_EE.CORE;

-- Helpers: models return "None", "-", "not recorded", "$1,650,000", "1,526", "2/25/2012"...
-- "not recorded" has to be on the list: the fuel question asks for exactly that
-- when the field is blank, and without it a blank fuel turns into 'Other'.
CREATE OR REPLACE FUNCTION CLEAN_TEXT(v STRING) RETURNS STRING AS
$$ IFF(LOWER(TRIM(v)) IN ('', 'none', 'null', '-', 'n/a', 'na', 'not recorded', 'not listed', 'blank', 'unknown', 'not available'),
       NULL, TRIM(v)) $$;

CREATE OR REPLACE FUNCTION CLEAN_NUMBER(v STRING) RETURNS NUMBER(14,2) AS
$$ TRY_TO_NUMBER(REGEXP_REPLACE(CLEAN_TEXT(v), '[^0-9.]', ''), 14, 2) $$;

CREATE OR REPLACE FUNCTION CLEAN_DATE(v STRING) RETURNS DATE AS
$$ COALESCE(TRY_TO_DATE(CLEAN_TEXT(v), 'YYYY-MM-DD'), TRY_TO_DATE(CLEAN_TEXT(v), 'MM/DD/YYYY')) $$;

-- Map whatever the town wrote to one vocabulary. Easier to audit here than in a prompt.
CREATE OR REPLACE FUNCTION NORMALIZE_FUEL(v STRING) RETURNS STRING AS
$$
  CASE
    WHEN CLEAN_TEXT(v) IS NULL                                   THEN NULL
    WHEN UPPER(v) RLIKE '.*(LP|PROPANE).*'                       THEN 'Propane'
    WHEN UPPER(v) RLIKE '.*GAS.*'                                THEN 'Gas'
    WHEN UPPER(v) RLIKE '.*OIL.*'                                THEN 'Oil'
    WHEN UPPER(v) RLIKE '.*(ELEC).*'                             THEN 'Electric'
    WHEN UPPER(v) RLIKE '.*(WOOD|COAL|PELLET).*'                 THEN 'Wood'
    ELSE 'Other'
  END
$$;

CREATE TABLE IF NOT EXISTS PROPERTY_ASSESSMENTS (
    municipality      STRING NOT NULL,
    parcel_id         STRING NOT NULL,
    address           STRING,
    owner_name        STRING,
    dwelling_style    STRING,
    year_built        NUMBER(4),
    year_remodeled    NUMBER(4),
    stories           NUMBER(3,1),
    living_area_sqft  NUMBER,
    total_rooms       NUMBER,
    bedrooms          NUMBER,
    full_baths        NUMBER,
    half_baths        NUMBER,
    heating_fuel      STRING,
    heating_fuel_raw  STRING,        -- exactly what the document said
    heating_system    STRING,
    ac_type           STRING,
    basement_type     STRING,
    roof_structure    STRING,
    last_sale_date    DATE,
    last_sale_price   NUMBER(14,2),
    assessed_value    NUMBER(14,2),
    min_field_score   FLOAT,         -- weakest field confidence on this record
    source_file       STRING,
    updated_at        TIMESTAMP_LTZ,
    CONSTRAINT pk_property PRIMARY KEY (municipality, parcel_id)
);

-- Field-level scores, one row per (file, field). Feeds the review queue and accuracy checks.
CREATE OR REPLACE VIEW FIELD_SCORES AS
SELECT e.file_name,
       f.key                        AS field_name,
       e.extracted:response[f.key]::STRING AS extracted_value,
       f.value:score::FLOAT         AS score
FROM ACME_EE.RAW.EXTRACTIONS e,
     LATERAL FLATTEN(input => e.extracted:scoring:scores) f;

-- Fields a person should look at, and what they changed them to. Created once and
-- never replaced, so re-running this script keeps saved corrections.
CREATE TABLE IF NOT EXISTS REVIEW_QUEUE (
    file_name       STRING,
    municipality    STRING,
    parcel_id       STRING,
    field_name      STRING,
    extracted_value STRING,
    score           FLOAT,
    status          STRING,
    corrected_value STRING,
    reviewed_by     STRING,
    reviewed_at     TIMESTAMP_LTZ
);

-- A reviewed correction replaces the model's answer before any cleanup runs,
-- so it goes through the same normalization and wins on every refresh.
CREATE OR REPLACE VIEW EXTRACTED_PROPERTIES AS
SELECT
    -- Trust the ingestion manifest first; fall back to what the model read.
    COALESCE(src.municipality,
      INITCAP(TRIM(SPLIT_PART(CLEAN_TEXT(r:municipality::STRING), ',', 1))) || ', ' ||
      UPPER(TRIM(SPLIT_PART(CLEAN_TEXT(r:municipality::STRING), ',', 2)))) AS municipality,
    CLEAN_TEXT(r:parcel_id::STRING)                    AS parcel_id,
    CLEAN_TEXT(r:address::STRING)                      AS address,
    INITCAP(CLEAN_TEXT(r:owner_name::STRING))          AS owner_name,
    INITCAP(CLEAN_TEXT(r:dwelling_style::STRING))      AS dwelling_style,
    CLEAN_NUMBER(r:year_built::STRING)::NUMBER(4)      AS year_built,
    CLEAN_NUMBER(r:year_remodeled::STRING)::NUMBER(4)  AS year_remodeled,
    CLEAN_NUMBER(r:stories::STRING)::NUMBER(3,1)       AS stories,
    CLEAN_NUMBER(r:living_area_sqft::STRING)::NUMBER   AS living_area_sqft,
    -- Scans: the model often skips the first number in "RMS/BR/FB/HB 7/4/2/1".
    -- A regex on the parsed text recovers it reliably.
    COALESCE(CLEAN_NUMBER(r:total_rooms::STRING),
             TRY_TO_NUMBER(REGEXP_SUBSTR(pd.content,
               'RMS/BR/FB/HB[^0-9]*([0-9]+)/([0-9]+)/([0-9]+)/([0-9]+)', 1, 1, 'e', 1)))::NUMBER AS total_rooms,
    CLEAN_NUMBER(r:bedrooms::STRING)::NUMBER           AS bedrooms,
    CLEAN_NUMBER(r:full_baths::STRING)::NUMBER         AS full_baths,
    CLEAN_NUMBER(r:half_baths::STRING)::NUMBER         AS half_baths,
    NORMALIZE_FUEL(r:heating_fuel::STRING)             AS heating_fuel,
    CLEAN_TEXT(r:heating_fuel::STRING)                 AS heating_fuel_raw,
    INITCAP(CLEAN_TEXT(r:heating_system::STRING))      AS heating_system,
    INITCAP(CLEAN_TEXT(r:ac_type::STRING))             AS ac_type,
    INITCAP(CLEAN_TEXT(r:basement_type::STRING))       AS basement_type,
    INITCAP(CLEAN_TEXT(r:roof_structure::STRING))      AS roof_structure,
    CLEAN_DATE(r:last_sale_date::STRING)               AS last_sale_date,
    CLEAN_NUMBER(r:last_sale_price::STRING)            AS last_sale_price,
    CLEAN_NUMBER(r:assessed_value::STRING)             AS assessed_value,
    e.min_score                                        AS min_field_score,
    e.file_name                                        AS source_file
FROM (
    -- A field a person corrected counts as fully confident.
    SELECT f.file_name,
           OBJECT_AGG(f.field_name, COALESCE(q.corrected_value, f.extracted_value)::VARIANT) AS r,
           MIN(IFF(q.corrected_value IS NOT NULL, 1, f.score))                             AS min_score
    FROM FIELD_SCORES f
    LEFT JOIN REVIEW_QUEUE q
      ON q.file_name = f.file_name AND q.field_name = f.field_name
     AND q.status = 'reviewed' AND TRIM(q.corrected_value) <> ''
    GROUP BY f.file_name
) e
LEFT JOIN ACME_EE.RAW.DOC_SOURCES src USING (file_name)
LEFT JOIN ACME_EE.RAW.PARSED_DOCS pd USING (file_name);

-- The one MERGE. The setup script, the nightly pipeline, and the app's
-- "Save reviewed rows" button all call this, so a correction shows up right away.
CREATE OR REPLACE PROCEDURE REFRESH_PROPERTIES()
RETURNS STRING
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
BEGIN
    MERGE INTO ACME_EE.CORE.PROPERTY_ASSESSMENTS t
    USING (SELECT * FROM ACME_EE.CORE.EXTRACTED_PROPERTIES
           WHERE municipality IS NOT NULL AND parcel_id IS NOT NULL
           QUALIFY ROW_NUMBER() OVER (PARTITION BY municipality, parcel_id ORDER BY source_file DESC) = 1) s
    ON t.municipality = s.municipality AND t.parcel_id = s.parcel_id
    WHEN MATCHED THEN UPDATE SET
        address = s.address, owner_name = s.owner_name, dwelling_style = s.dwelling_style,
        year_built = s.year_built, year_remodeled = s.year_remodeled, stories = s.stories,
        living_area_sqft = s.living_area_sqft, total_rooms = s.total_rooms, bedrooms = s.bedrooms,
        full_baths = s.full_baths, half_baths = s.half_baths, heating_fuel = s.heating_fuel,
        heating_fuel_raw = s.heating_fuel_raw, heating_system = s.heating_system, ac_type = s.ac_type,
        basement_type = s.basement_type, roof_structure = s.roof_structure,
        last_sale_date = s.last_sale_date, last_sale_price = s.last_sale_price,
        assessed_value = s.assessed_value, min_field_score = s.min_field_score,
        source_file = s.source_file, updated_at = CURRENT_TIMESTAMP()
    WHEN NOT MATCHED THEN INSERT VALUES (
        s.municipality, s.parcel_id, s.address, s.owner_name, s.dwelling_style, s.year_built,
        s.year_remodeled, s.stories, s.living_area_sqft, s.total_rooms, s.bedrooms, s.full_baths,
        s.half_baths, s.heating_fuel, s.heating_fuel_raw, s.heating_system, s.ac_type,
        s.basement_type, s.roof_structure, s.last_sale_date, s.last_sale_price, s.assessed_value,
        s.min_field_score, s.source_file, CURRENT_TIMESTAMP());
    RETURN SQLROWCOUNT || ' rows merged';
END;
$$;

CALL REFRESH_PROPERTIES();

-- Fields a person should look at. 0.8 comes from measurement, not intuition:
-- on the 336 labeled fields, 292 of the 293 values scoring >= 0.8 were correct
-- (see 08_cost_and_accuracy.sql).
-- Only adds fields not already queued, so reviewed rows are never touched.
INSERT INTO REVIEW_QUEUE
SELECT f.file_name, p.municipality, p.parcel_id, f.field_name, f.extracted_value, f.score,
       'open', NULL, NULL, NULL
FROM FIELD_SCORES f
LEFT JOIN PROPERTY_ASSESSMENTS p ON p.source_file = f.file_name
WHERE (f.score < 0.8
       -- a blank on a field we target programs with always gets a human look
       OR (f.field_name IN ('heating_fuel', 'year_built', 'living_area_sqft') AND CLEAN_TEXT(f.extracted_value) IS NULL))
  AND NOT EXISTS (SELECT 1 FROM REVIEW_QUEUE q
                  WHERE q.file_name = f.file_name AND q.field_name = f.field_name);
