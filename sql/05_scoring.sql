-- 05_scoring.sql
-- Turn property facts into program leads: which homes fit which measure,
-- roughly how much they'd save, and a first-draft outreach letter.
--
-- The savings numbers below are ILLUSTRATIVE placeholders. A real program uses
-- its state Technical Reference Manual (MA uses the Mass Save TRM, CT the
-- CT Program Savings Document). Keep therms and kWh in separate columns;
-- adding them together is the classic mistake.

USE ROLE ACME_ENGINEER;
USE WAREHOUSE ACME_EE_WH;
USE SCHEMA ACME_EE.CORE;

CREATE OR REPLACE TABLE DEEMED_SAVINGS (
    measure            STRING,
    heating_fuel       STRING,     -- fuel this savings value applies to
    therms_per_ksf     NUMBER(8,1),-- annual natural gas savings per 1,000 sq ft
    gallons_per_ksf    NUMBER(8,1),-- annual oil/propane gallons per 1,000 sq ft
    kwh_per_ksf        NUMBER(8,1),-- annual electric savings (negative = added load)
    source_note        STRING
);

INSERT INTO DEEMED_SAVINGS VALUES
  ('Weatherization',      'Gas',      110,    0,    40, 'illustrative'),
  ('Weatherization',      'Oil',        0,   80,    40, 'illustrative'),
  ('Weatherization',      'Propane',    0,  110,    40, 'illustrative'),
  ('Weatherization',      'Electric',   0,    0,  1800, 'illustrative'),
  ('Heat pump conversion','Oil',        0,  350, -3200, 'illustrative; adds electric load'),
  ('Heat pump conversion','Propane',    0,  480, -3200, 'illustrative; adds electric load'),
  ('Heat pump conversion','Electric',   0,    0,  4500, 'illustrative; replaces resistance heat'),
  ('Heat pump water heater','Electric', 0,    0,  1100, 'illustrative; per home, not per ksf');

-- Rules a program manager can read. Each row = one home x one measure.
CREATE OR REPLACE VIEW PROGRAM_RECOMMENDATIONS AS
WITH homes AS (
  SELECT p.*, COALESCE(p.year_remodeled, p.year_built) AS effective_year
  FROM PROPERTY_ASSESSMENTS p
), matches AS (
  SELECT h.*, 'Weatherization' AS measure,
         'Built ' || h.year_built || IFF(h.year_remodeled IS NULL, ', never remodeled', ', remodeled ' || h.year_remodeled) AS reason
  FROM homes h WHERE h.effective_year < 1980 AND h.heating_fuel IS NOT NULL
  UNION ALL
  SELECT h.*, 'Heat pump conversion', 'Heats with ' || h.heating_fuel_raw
  FROM homes h WHERE h.heating_fuel IN ('Oil', 'Propane', 'Electric')
  UNION ALL
  SELECT h.*, 'Heat pump water heater', 'Electric home'
  FROM homes h WHERE h.heating_fuel = 'Electric'
  UNION ALL
  -- No fuel on the card: don't guess. Send someone to look.
  SELECT h.*, 'Field verification', 'Heating fuel not recorded'
  FROM homes h WHERE h.heating_fuel IS NULL
)
SELECT
  m.municipality, m.parcel_id, m.address, m.owner_name, m.dwelling_style,
  m.year_built, m.year_remodeled, m.living_area_sqft, m.heating_fuel, m.heating_system,
  m.assessed_value, m.measure, m.reason,
  ROUND(d.therms_per_ksf  * m.living_area_sqft / 1000) AS est_therms_saved,
  ROUND(d.gallons_per_ksf * m.living_area_sqft / 1000) AS est_gallons_saved,
  ROUND(IFF(m.measure = 'Heat pump water heater', d.kwh_per_ksf,
            d.kwh_per_ksf * m.living_area_sqft / 1000)) AS est_kwh_saved,
  -- A screen, not a determination: income eligibility needs an application.
  m.assessed_value < 250000 AS lmi_prescreen,
  m.min_field_score,
  m.min_field_score < 0.8 AS has_open_review_items
FROM matches m
LEFT JOIN DEEMED_SAVINGS d ON d.measure = m.measure AND d.heating_fuel = m.heating_fuel;

-- First-draft outreach letters. A person approves every letter before it goes out.
CREATE TABLE IF NOT EXISTS OUTREACH_DRAFTS (
    municipality STRING, parcel_id STRING, measure STRING,
    letter STRING, model STRING, status STRING DEFAULT 'draft',
    created_at TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP()
);

INSERT INTO OUTREACH_DRAFTS (municipality, parcel_id, measure, letter, model)
SELECT r.municipality, r.parcel_id, r.measure,
       AI_COMPLETE('claude-sonnet-4-5',
         'Write a short, friendly letter (under 150 words) from the ACME Energy Efficiency team '
         || 'to the homeowner at ' || r.address || ', ' || r.municipality || '. '
         || 'The home is a ' || COALESCE(r.dwelling_style, 'house') || ' built in ' || r.year_built
         || ' that heats with ' || COALESCE(r.heating_fuel, 'an unknown fuel') || '. '
         || 'Suggest a no-cost home energy assessment and mention this program: ' || r.measure || '. '
         || 'Do not promise specific dollar savings or rebate amounts. Do not mention income, '
         || 'assessed value, or how we found the home. Plain language, no exclamation marks. '
         || 'Sign off as "The ACME Energy Efficiency Team". Return only the letter text.'),
       'claude-sonnet-4-5'
FROM PROGRAM_RECOMMENDATIONS r
WHERE r.measure <> 'Field verification'
  AND NOT EXISTS (SELECT 1 FROM OUTREACH_DRAFTS o
                  WHERE o.municipality = r.municipality AND o.parcel_id = r.parcel_id AND o.measure = r.measure)
QUALIFY ROW_NUMBER() OVER (ORDER BY COALESCE(est_therms_saved, 0) + COALESCE(est_gallons_saved, 0) DESC) <= 5;
