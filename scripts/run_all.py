"""Run the whole demo from an empty database.

    .venv/bin/python scripts/run_all.py --connection <your_connection> --fresh

--fresh drops the database first. Each sql/*.sql file is executed as written,
with the database, warehouse and role names swapped for the ones you pick
(defaults: ACME_EE, ACME_EE_WH, ACME_ENGINEER / ACME_ANALYST / ACME_PROGRAM_MGR).
The PUT uploads that the files describe in comments happen here.
"""
import argparse
import pathlib
import re
import tempfile
import time

import snowflake.connector

ROOT = pathlib.Path(__file__).resolve().parent.parent
SQL = ROOT / "sql"
NAME = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")


def namer(database, warehouse, role_prefix):
    """Return a function that rewrites the default object names in a piece of text."""
    swaps = [
        ("ACME_EE_WH", warehouse),
        ("ACME_EE", database),
        ("ACME_ENGINEER", f"{role_prefix}_ENGINEER"),
        ("ACME_ANALYST", f"{role_prefix}_ANALYST"),
        ("ACME_PROGRAM_MGR", f"{role_prefix}_PROGRAM_MGR"),
    ]

    def rename(text):
        for old, new in swaps:
            text = re.sub(rf"\b{old}\b", new, text)
        return text

    return rename


def run(cur, sql):
    cur.execute(sql)
    return cur.fetchall()


def run_file(conn, name, rename):
    t0 = time.time()
    last = None
    for cur in conn.execute_string(rename((SQL / name).read_text()), remove_comments=True):
        last = cur
    print(f"  {name}: {time.time() - t0:.1f}s")
    return last


def put(cur, local, stage):
    rows = run(cur, f"PUT 'file://{local}' {stage} AUTO_COMPRESS = FALSE OVERWRITE = TRUE")
    print(f"  PUT {len(rows)} file(s) -> {stage}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--connection", required=True)
    ap.add_argument("--expect-account", default=None,
                    help="stop unless CURRENT_ACCOUNT() matches (safety for multi-account setups)")
    ap.add_argument("--fresh", action="store_true", help="drop the database first")
    ap.add_argument("--database", default="ACME_EE", help="database to build in (default ACME_EE)")
    ap.add_argument("--warehouse", default=None, help="warehouse to create and use (default <database>_WH)")
    ap.add_argument("--role-prefix", default="ACME",
                    help="prefix for the three roles: <prefix>_ENGINEER, <prefix>_ANALYST, <prefix>_PROGRAM_MGR")
    args = ap.parse_args()

    database = args.database.upper()
    warehouse = (args.warehouse or f"{database}_WH").upper()
    prefix = args.role_prefix.upper()
    for value in (database, warehouse, prefix):
        if not NAME.match(value):
            raise SystemExit(f"{value!r} isn't a valid name: use letters, numbers and underscores")
    rename = namer(database, warehouse, prefix)
    engineer, program_mgr = f"{prefix}_ENGINEER", f"{prefix}_PROGRAM_MGR"

    conn = snowflake.connector.connect(connection_name=args.connection)
    cur = conn.cursor()
    account = run(cur, "SELECT CURRENT_ACCOUNT()")[0][0]
    print(f"connected to {account}")
    if args.expect_account and account != args.expect_account:
        raise SystemExit(f"expected {args.expect_account}, got {account}; stopping")
    print(f"database {database}, warehouse {warehouse}, roles {prefix}_*")

    start = time.time()
    if args.fresh:
        run(cur, "USE ROLE ACCOUNTADMIN")
        run(cur, f"DROP DATABASE IF EXISTS {database}")
        print(f"  dropped {database}")

    run_file(conn, "00_setup.sql", rename)
    run_file(conn, "01_stage.sql", rename)
    run(cur, f"USE ROLE {engineer}")
    put(cur, ROOT / "data" / "docs" / "*", f"@{database}.RAW.ASSESSOR_DOCS")
    run(cur, f"ALTER STAGE {database}.RAW.ASSESSOR_DOCS REFRESH")
    for name in ["02_extract.sql", "03_merge.sql", "04_automate.sql",
                 "05_scoring.sql", "06_governance.sql", "07_agent.sql"]:
        run_file(conn, name, rename)

    run(cur, f"USE ROLE {engineer}")
    run(cur, f"CREATE STAGE IF NOT EXISTS {database}.RAW.REFERENCE_FILES ENCRYPTION = (TYPE = 'SNOWFLAKE_SSE')")
    put(cur, ROOT / "data" / "labels.csv", f"@{database}.RAW.REFERENCE_FILES")
    run_file(conn, "08_cost_and_accuracy.sql", rename)

    run(cur, f"USE ROLE {engineer}")
    run(cur, f"GRANT CREATE STAGE, CREATE STREAMLIT ON SCHEMA {database}.APP TO ROLE {program_mgr}")
    run(cur, f"USE ROLE {program_mgr}")
    run(cur, f"CREATE STAGE IF NOT EXISTS {database}.APP.STREAMLIT_SRC ENCRYPTION = (TYPE = 'SNOWFLAKE_SSE')")
    # The app has the database name in its queries, so upload a copy with your names in it.
    with tempfile.TemporaryDirectory() as tmp:
        app = pathlib.Path(tmp) / "streamlit_app.py"
        app.write_text(rename((ROOT / "streamlit" / "streamlit_app.py").read_text()))
        put(cur, app, f"@{database}.APP.STREAMLIT_SRC")
    put(cur, ROOT / "streamlit" / "environment.yml", f"@{database}.APP.STREAMLIT_SRC")
    run_file(conn, "09_app.sql", rename)

    print(f"done in {time.time() - start:.0f}s")
    conn.close()


if __name__ == "__main__":
    main()
