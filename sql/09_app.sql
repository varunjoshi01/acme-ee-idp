-- 09_app.sql
-- The Streamlit app runs with its owner's rights. Make the program manager
-- the owner, so the masking and territory policies apply inside the app too.

USE ROLE ACME_ENGINEER;
GRANT USAGE ON SCHEMA ACME_EE.RAW TO ROLE ACME_PROGRAM_MGR;
GRANT READ ON STAGE ACME_EE.RAW.ASSESSOR_DOCS TO ROLE ACME_PROGRAM_MGR;
GRANT SELECT ON TABLE ACME_EE.RAW.EXTRACTIONS TO ROLE ACME_PROGRAM_MGR;
GRANT CREATE STAGE, CREATE STREAMLIT ON SCHEMA ACME_EE.APP TO ROLE ACME_PROGRAM_MGR;

USE ROLE ACME_PROGRAM_MGR;
CREATE STAGE IF NOT EXISTS ACME_EE.APP.STREAMLIT_SRC ENCRYPTION = (TYPE = 'SNOWFLAKE_SSE');

-- PUT 'file://streamlit/streamlit_app.py' @ACME_EE.APP.STREAMLIT_SRC AUTO_COMPRESS = FALSE OVERWRITE = TRUE;
-- PUT 'file://streamlit/environment.yml'  @ACME_EE.APP.STREAMLIT_SRC AUTO_COMPRESS = FALSE OVERWRITE = TRUE;
-- Warehouse runtime, pinned explicitly. On this account the default was the
-- container runtime, which first wanted a pyproject.toml and then hung on
-- "Waiting for response from server". The warehouse runtime starts on the
-- warehouse we already have.

CREATE OR REPLACE STREAMLIT ACME_EE.APP.EE_LEADS_APP
  FROM '@ACME_EE.APP.STREAMLIT_SRC'
  MAIN_FILE = 'streamlit_app.py'
  QUERY_WAREHOUSE = ACME_EE_WH
  RUNTIME_NAME = 'SYSTEM$WAREHOUSE_RUNTIME'
  TITLE = 'ACME home energy leads';
