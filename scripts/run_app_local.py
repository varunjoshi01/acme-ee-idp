"""Run streamlit/streamlit_app.py on your laptop instead of in Snowflake.

    SNOWFLAKE_CONNECTION=<your_connection> .venv/bin/streamlit run scripts/run_app_local.py

In Snowflake the app gets its session from get_active_session(). Here we build
one from a named connection and hand it to that call.

Optional settings, matching the run_all.py options you built with:
    APP_ROLE         role to run as (default <prefix>_PROGRAM_MGR)
    ACME_DATABASE    database name (default ACME_EE)
    ACME_WAREHOUSE   warehouse name (default <database>_WH)
    ACME_ROLE_PREFIX role prefix (default ACME)
"""
import functools
import os
import pathlib

import snowflake.snowpark.context as ctx
from snowflake.snowpark import Session

from run_all import namer

CONNECTION = os.environ.get("SNOWFLAKE_CONNECTION", "default")
DATABASE = os.environ.get("ACME_DATABASE", "ACME_EE").upper()
WAREHOUSE = os.environ.get("ACME_WAREHOUSE", f"{DATABASE}_WH").upper()
PREFIX = os.environ.get("ACME_ROLE_PREFIX", "ACME").upper()
ROLE = os.environ.get("APP_ROLE", f"{PREFIX}_PROGRAM_MGR")


@functools.lru_cache(maxsize=1)
def _session():
    s = Session.builder.config("connection_name", CONNECTION).create()
    s.sql(f"USE ROLE {ROLE}").collect()
    s.sql("USE SECONDARY ROLES NONE").collect()
    s.sql(f"USE WAREHOUSE {WAREHOUSE}").collect()
    return s


ctx.get_active_session = _session
app = pathlib.Path(__file__).resolve().parent.parent / "streamlit" / "streamlit_app.py"
exec(compile(namer(DATABASE, WAREHOUSE, PREFIX)(app.read_text()), str(app), "exec"), {"__name__": "__main__"})
