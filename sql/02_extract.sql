-- 02_extract.sql
-- Read every new document with AI_PARSE_DOCUMENT (full text) and AI_EXTRACT
-- (21 structured fields with confidence scores).
--
-- Routing rule, learned by measuring against the answer key (data/labels.csv):
--   * Digital files (HTML, born-digital PDF): AI_EXTRACT reads the file directly.
--   * Scans: parse first, then run AI_EXTRACT on the parsed text.
--     On our four scans this lifted field accuracy from 90.5% to 94.0%.
--
-- Things the questions have to handle:
--   * Scanned cards often pack counts into one field ("RMS/BR/FB/HB 7/4/2/1").
--   * A handwritten "furnace repl. 2019" note can pull the sale year to 2019,
--     so the sale-date question points at the sale line only.
--   * Asking the model to normalize ("LP" -> Propane) doesn't stick.
--     Ask for what's written; normalize in SQL (03_merge.sql).

USE ROLE ACME_ENGINEER;
USE WAREHOUSE ACME_EE_WH;
USE SCHEMA ACME_EE.RAW;

CREATE TABLE IF NOT EXISTS EXTRACTIONS (
    file_name      STRING,
    file_url       STRING,
    last_modified  TIMESTAMP_TZ,
    extracted      VARIANT,          -- raw AI_EXTRACT output, kept for audit
    extracted_at   TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP()
);

CREATE TABLE IF NOT EXISTS PARSED_DOCS (
    file_name      STRING,
    content        STRING,           -- Markdown from AI_PARSE_DOCUMENT LAYOUT mode
    page_count     NUMBER,
    parsed_at      TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP()
);

-- One place for the extraction questions, so every run uses the same prompt.
CREATE OR REPLACE FUNCTION EXTRACTION_SCHEMA()
RETURNS OBJECT
AS
$$
  {
    'municipality': 'Which city or town and state is this property in? Answer like "Springfield, MA".',
    'parcel_id': 'What is the parcel ID, map ID, or map/lot number?',
    'address': 'What is the property street address (location), not the owner mailing address?',
    'owner_name': 'Who is the current owner of record?',
    'dwelling_style': 'What is the building style, for example Cape, Colonial, Ranch? Give only the style word.',
    'year_built': 'What year was the house originally built?',
    'year_remodeled': 'What year was the house remodeled or renovated? Answer empty if there was no remodel.',
    'stories': 'How many stories does the house have?',
    'living_area_sqft': 'What is the finished or gross living area in square feet?',
    'total_rooms': 'How many total rooms? Counts may be combined in one field like RMS/BR/FB/HB 7/4/2/1, where the first number is rooms.',
    'bedrooms': 'How many bedrooms? Counts may be combined in one field like RMS/BR/FB/HB 7/4/2/1, where the second number is bedrooms.',
    'full_baths': 'How many full bathrooms? In a combined RMS/BR/FB/HB field this is the third number.',
    'half_baths': 'How many half bathrooms? In a combined RMS/BR/FB/HB field this is the fourth number.',
    'heating_fuel': 'What heating fuel is listed in the heat fuel field? Copy it as written. Answer empty if it is blank or not recorded.',
    'heating_system': 'What type of heating system or heat distribution is listed?',
    'ac_type': 'What type of air conditioning is listed, or None?',
    'basement_type': 'What type of basement or foundation is listed?',
    'roof_structure': 'What is the roof structure or roof form?',
    'last_sale_date': 'What is the date of the most recent sale or deed, from the sale or deed line only (ignore handwritten notes)? Use YYYY-MM-DD.',
    'last_sale_price': 'What was the price of the most recent sale?',
    'assessed_value': 'What is the total appraised or assessed value? Use the full appraised value, not a 70 percent assessment.'
  }
$$;

-- 1. Full text for every new file. LAYOUT keeps tables readable (OCR is the default).
--    Third argument TRUE returns {value, error, metadata} so failures don't vanish as NULLs.
INSERT INTO PARSED_DOCS (file_name, content, page_count)
SELECT relative_path, r:value:content::STRING, r:metadata:pageCount::NUMBER
FROM (
  SELECT d.relative_path,
         AI_PARSE_DOCUMENT(TO_FILE('@ACME_EE.RAW.ASSESSOR_DOCS', d.relative_path),
                           {'mode': 'LAYOUT'}, TRUE) AS r
  FROM DIRECTORY(@ACME_EE.RAW.ASSESSOR_DOCS) d
  WHERE d.relative_path NOT IN (SELECT file_name FROM PARSED_DOCS)
);

-- 2a. Digital documents: extract straight from the file.
INSERT INTO EXTRACTIONS (file_name, file_url, last_modified, extracted)
SELECT d.relative_path, d.file_url, d.last_modified,
       AI_EXTRACT(file => TO_FILE('@ACME_EE.RAW.ASSESSOR_DOCS', d.relative_path),
                  responseFormat => EXTRACTION_SCHEMA(),
                  scores => TRUE)
FROM DIRECTORY(@ACME_EE.RAW.ASSESSOR_DOCS) d
JOIN DOC_SOURCES s ON s.file_name = d.relative_path
WHERE s.source_type <> 'scan'
  AND d.relative_path NOT IN (SELECT file_name FROM EXTRACTIONS);

-- 2b. Scans: extract from the parsed text.
INSERT INTO EXTRACTIONS (file_name, file_url, last_modified, extracted)
SELECT p.file_name, d.file_url, d.last_modified,
       AI_EXTRACT(text => p.content,
                  responseFormat => EXTRACTION_SCHEMA(),
                  scores => TRUE)
FROM PARSED_DOCS p
JOIN DIRECTORY(@ACME_EE.RAW.ASSESSOR_DOCS) d ON d.relative_path = p.file_name
JOIN DOC_SOURCES s ON s.file_name = p.file_name
WHERE s.source_type = 'scan'
  AND p.file_name NOT IN (SELECT file_name FROM EXTRACTIONS);
