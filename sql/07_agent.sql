-- 07_agent.sql
-- Ask the data questions in plain English. Three pieces:
--   1. a semantic view (what the numbers mean),
--   2. a Cortex Search service over the original documents,
--   3. a Cortex Agent that picks between them.

USE ROLE ACME_ENGINEER;
USE WAREHOUSE ACME_EE_WH;

CREATE OR REPLACE SEMANTIC VIEW ACME_EE.CORE.EE_PROGRAM_SV
  TABLES (
    homes AS ACME_EE.CORE.PROPERTY_ASSESSMENTS PRIMARY KEY (municipality, parcel_id)
      COMMENT = 'One row per residential property, extracted from municipal assessor records',
    recs AS ACME_EE.CORE.PROGRAM_RECOMMENDATIONS PRIMARY KEY (municipality, parcel_id, measure)
      COMMENT = 'One row per home and energy-efficiency measure it qualifies for'
  )
  RELATIONSHIPS (
    recs_to_homes AS recs (municipality, parcel_id) REFERENCES homes
  )
  FACTS (
    homes.living_area AS living_area_sqft COMMENT = 'Finished living area in square feet',
    homes.assessed AS assessed_value COMMENT = 'Full appraised value in USD',
    recs.therms_saved AS est_therms_saved COMMENT = 'Illustrative annual natural gas savings, therms',
    recs.gallons_saved AS est_gallons_saved COMMENT = 'Illustrative annual oil or propane savings, gallons',
    recs.kwh_saved AS est_kwh_saved COMMENT = 'Illustrative annual electric savings in kWh; negative means added load'
  )
  DIMENSIONS (
    homes.municipality AS municipality WITH SYNONYMS = ('town', 'city') COMMENT = 'City or town and state, e.g. Springfield, MA',
    homes.state AS TRIM(SPLIT_PART(municipality, ',', 2)) COMMENT = 'Two-letter state code, MA or CT',
    homes.parcel_id AS parcel_id COMMENT = 'Assessor parcel or map/lot ID',
    homes.address AS address COMMENT = 'Property street address',
    homes.owner_name AS owner_name COMMENT = 'Owner of record',
    homes.dwelling_style AS dwelling_style COMMENT = 'Building style such as Cape, Colonial, Ranch',
    homes.year_built AS year_built COMMENT = 'Year originally built',
    homes.year_remodeled AS year_remodeled COMMENT = 'Year remodeled, null if never',
    homes.heating_fuel AS heating_fuel WITH SYNONYMS = ('fuel', 'heat source') COMMENT = 'Normalized fuel: Gas, Oil, Propane, Electric, Wood, Other; null if not recorded',
    homes.heating_system AS heating_system COMMENT = 'Heat distribution, e.g. Forced Air, Hot Water',
    recs.measure AS measure WITH SYNONYMS = ('program', 'offer') COMMENT = 'Weatherization, Heat pump conversion, Heat pump water heater, or Field verification',
    recs.reason AS reason COMMENT = 'Why the home matched the measure',
    recs.lmi_prescreen AS lmi_prescreen COMMENT = 'TRUE when assessed value is under 250k; a screen only, not an income determination'
  )
  METRICS (
    homes.home_count AS COUNT(homes.parcel_id) COMMENT = 'Number of homes',
    homes.avg_year_built AS AVG(homes.year_built) COMMENT = 'Average year built',
    recs.lead_count AS COUNT(recs.parcel_id) COMMENT = 'Number of home-measure matches (leads)',
    recs.total_therms_saved AS SUM(recs.therms_saved) COMMENT = 'Total illustrative therms saved per year',
    recs.total_gallons_saved AS SUM(recs.gallons_saved) COMMENT = 'Total illustrative gallons saved per year',
    recs.total_kwh_saved AS SUM(recs.kwh_saved) COMMENT = 'Total illustrative kWh change per year'
  )
  COMMENT = 'ACME energy-efficiency program targeting: homes, measures, illustrative savings';

-- The raw document text is NOT masked (owner names are in it), so grant this narrowly.
CREATE OR REPLACE CORTEX SEARCH SERVICE ACME_EE.CORE.ASSESSOR_DOC_SEARCH
  ON content
  ATTRIBUTES municipality, file_name
  WAREHOUSE = ACME_EE_WH
  TARGET_LAG = '1 day'
  COMMENT = 'Full text of assessor records; contains unmasked owner names, so grant narrowly'
AS
  SELECT p.file_name, s.municipality, p.content
  FROM ACME_EE.RAW.PARSED_DOCS p JOIN ACME_EE.RAW.DOC_SOURCES s USING (file_name);

CREATE OR REPLACE AGENT ACME_EE.APP.EE_PROGRAM_AGENT
  COMMENT = 'Answers program-targeting questions over extracted assessor data'
  FROM SPECIFICATION
$$
models:
  orchestration: auto
instructions:
  system: "You help an energy-efficiency program team decide which homes to contact. Savings figures are illustrative placeholders, not Technical Reference Manual values; say so when you report them. The LMI flag is a pre-screen based on assessed value, never an income determination."
  orchestration: "Use program_data for counts, totals, lists of homes and measures. Use assessor_records only when the user asks what a specific property card or document says."
  response: "Be brief. Lead with the number or list. Keep therms, gallons and kWh as separate figures; never add them together."
  sample_questions:
    - question: "How many homes qualify for a heat pump conversion, by state?"
    - question: "Which towns have the most weatherization leads?"
    - question: "What does the assessor card for 242 Ocean Drive West say about heating?"
tools:
  - tool_spec:
      type: cortex_analyst_text_to_sql
      name: program_data
      description: "Homes extracted from municipal assessor records and the efficiency measures each qualifies for, with illustrative savings."
  - tool_spec:
      type: cortex_search
      name: assessor_records
      description: "Full text of the original assessor documents (HTML pages, PDFs, scanned cards)."
tool_resources:
  program_data:
    semantic_view: ACME_EE.CORE.EE_PROGRAM_SV
    execution_environment:
      type: warehouse
      warehouse: ACME_EE_WH
  assessor_records:
    search_service: ACME_EE.CORE.ASSESSOR_DOC_SEARCH
    id_column: FILE_NAME
    title_column: FILE_NAME
    max_results: 3
$$;

-- An agent needs the caller to hold every object it touches:
-- the agent, the semantic view, the tables underneath, and the search service.
GRANT USAGE ON AGENT ACME_EE.APP.EE_PROGRAM_AGENT TO ROLE ACME_PROGRAM_MGR;
GRANT SELECT ON SEMANTIC VIEW ACME_EE.CORE.EE_PROGRAM_SV TO ROLE ACME_PROGRAM_MGR;
GRANT SELECT ON SEMANTIC VIEW ACME_EE.CORE.EE_PROGRAM_SV TO ROLE ACME_ANALYST;
GRANT USAGE ON CORTEX SEARCH SERVICE ACME_EE.CORE.ASSESSOR_DOC_SEARCH TO ROLE ACME_PROGRAM_MGR;

-- Try it from SQL, no REST client needed:
-- USE ROLE ACME_PROGRAM_MGR; USE SECONDARY ROLES NONE;
-- SELECT TRY_PARSE_JSON(SNOWFLAKE.CORTEX.DATA_AGENT_RUN('ACME_EE.APP.EE_PROGRAM_AGENT',
--   $${"messages":[{"role":"user","content":[{"type":"text",
--      "text":"How many homes qualify for a heat pump conversion, by state?"}]}],"stream":false}$$));
