# ACME home energy leads

Town assessors publish a property record card for every house: year built, heating fuel,
square footage, last sale. That's most of what a utility efficiency program needs to find
good candidates for weatherization or a heat pump. The catch is that every town publishes
it differently: HTML pages, PDFs, and scanned paper cards with notes in the margin.

This repo reads those records with Snowflake's `AI_PARSE_DOCUMENT` and `AI_EXTRACT`, cleans
the answers in SQL, matches homes to programs, and puts a Cortex Agent on top so a program
manager can ask questions in plain English. Masking and row access policies apply to all of
it, the agent included. It all runs inside Snowflake.

## What's here

| Path | What it does |
|---|---|
| `scripts/make_sample_docs.py` | Builds the 16 test documents in 4 formats, plus `data/labels.csv` with the right answers |
| `sql/00_setup.sql` | Database, warehouse, roles, AI privileges |
| `sql/01_stage.sql` | Encrypted stage, directory table, stream, file manifest |
| `sql/02_extract.sql` | `AI_PARSE_DOCUMENT` and `AI_EXTRACT` (scans are parsed first, then extracted) |
| `sql/03_merge.sql` | Cleanup functions, a MERGE you can re-run safely, the review queue |
| `sql/04_automate.sql` | `RUN_PIPELINE()` and a nightly task that only runs when new files arrive |
| `sql/05_scoring.sql` | Placeholder savings, program rules, draft letters with `AI_COMPLETE` |
| `sql/06_governance.sql` | Masking, row access by state, grants |
| `sql/07_agent.sql` | Semantic view, Cortex Search service, Cortex Agent |
| `sql/08_cost_and_accuracy.sql` | Accuracy against the answer key, score bands, cost, timing |
| `sql/09_app.sql` | Grants and `CREATE STREAMLIT` for the app |
| `sql/10_volume_test.sql` | Optional: the same pipeline over 500 generated documents |
| `scripts/run_all.py` | Builds everything from an empty database |
| `scripts/run_app_local.py` | Runs the Streamlit app on your laptop against your account |
| `streamlit/streamlit_app.py` | Pipeline status, lead list, review queue, and a chat tab for the agent |

## Run it

These steps take you from nothing to a working pipeline, agent and app. Plan on about
30 minutes the first time. Most of that is setup; the build itself takes a few minutes.

### Step 1: Check what you need

- **A Snowflake account where you can use the `ACCOUNTADMIN` role.** A free
  [30-day trial](https://signup.snowflake.com/) works. The setup script uses `ACCOUNTADMIN`
  once to create the database, warehouse and roles.
- **Python 3.9 or newer.** Check with `python3 --version`. If you don't have it, install it
  from [python.org](https://www.python.org/downloads/).
- **Git**, to download the code. Check with `git --version`. If you don't have it, you can
  use GitHub's **Code → Download ZIP** button instead.

The commands below are for macOS and Linux. On Windows, use PowerShell and replace
`.venv/bin/` with `.venv\Scripts\`.

### Step 2: Download the code

```bash
git clone https://github.com/varunjoshi01/acme-ee-idp.git
cd acme-ee-idp
```

Run every command after this from inside the `acme-ee-idp` folder.

### Step 3: Tell the scripts how to connect to Snowflake

The scripts read your login details from a file called `connections.toml`. Create the
folder and file if they don't exist:

- macOS and Linux: `~/.snowflake/connections.toml`
- Windows: `%USERPROFILE%\.snowflake\connections.toml`

Put this in it, with your own values:

```toml
[acme]
account = "myorg-myaccount"
user = "MY_USER"
password = "my-password"
```

- `acme` is the connection name. You'll pass it to the scripts later.
- To find `account`, log in to Snowsight, click your name in the bottom-left corner and choose
  **Connect a tool to Snowflake**. The **Account identifier** is shown there, and the
  **Config file** tab gives you a ready-made version of this file.
- If you sign in with SSO, replace the `password` line with `authenticator = "externalbrowser"`.
  A browser tab will open to log you in each time a script connects.
- If your account requires MFA, you'll get a push notification when a script connects.

On macOS and Linux, keep the file private with `chmod 600 ~/.snowflake/connections.toml`.

### Step 4: Make sure the AI functions are available

`AI_EXTRACT`, `AI_PARSE_DOCUMENT` and the Cortex Agent are not available in every region.
If you're not sure about yours, turn on cross-region inference. In Snowsight, open a new SQL
worksheet and run:

```sql
USE ROLE ACCOUNTADMIN;
ALTER ACCOUNT SET CORTEX_ENABLED_CROSS_REGION = 'ANY_REGION';
```

This lets Snowflake run the AI calls in another region if yours doesn't support them.
Skip it if your company doesn't allow data to be processed outside your region.

### Step 5: Install the Python packages

This creates a private Python environment in a `.venv` folder, so nothing is installed
system-wide:

```bash
python3 -m venv .venv
.venv/bin/pip install reportlab pillow pypdf snowflake-connector-python "snowflake-snowpark-python[pandas]" streamlit
```

### Step 6: Create the test documents

```bash
.venv/bin/python scripts/make_sample_docs.py
```

This writes 16 property records to `data/docs/`: HTML pages, PDFs and scanned images. It also
writes `data/labels.csv`, the right answer for every field, which is used later to measure
accuracy.

### Step 7: Build everything in Snowflake

```bash
.venv/bin/python scripts/run_all.py --connection acme --fresh
```

By default this creates a database called `ACME_EE`, a warehouse called `ACME_EE_WH` and three
roles called `ACME_ENGINEER`, `ACME_ANALYST` and `ACME_PROGRAM_MGR`. If any of those names are
already taken in your account, or you want to keep a second copy, pick your own:

```bash
.venv/bin/python scripts/run_all.py --connection acme --fresh \
    --database MY_EE_TEST --warehouse MY_EE_TEST_WH --role-prefix MY_EE_TEST
```

| Option | What it names | Default |
|---|---|---|
| `--database` | The database everything is built in | `ACME_EE` |
| `--warehouse` | The warehouse the build creates and uses | `<database>_WH` |
| `--role-prefix` | The three roles: `<prefix>_ENGINEER`, `<prefix>_ANALYST`, `<prefix>_PROGRAM_MGR` | `ACME` |

The schemas inside the database (`RAW`, `CORE`, `APP`) keep their names, since a new
database already keeps them separate. The SQL files in `sql/` are written with the default
names; the script swaps in yours as it runs them. If you picked your own names, use them in
place of the defaults in steps 8 to 10 as well.

The script:

1. Creates the database `ACME_EE`, the warehouse `ACME_EE_WH` and three roles (`ACME_ENGINEER`,
   `ACME_ANALYST`, `ACME_PROGRAM_MGR`), and grants all three to your user.
2. Uploads the documents and reads them with `AI_PARSE_DOCUMENT` and `AI_EXTRACT`.
3. Cleans the results into one table, scores homes for programs and drafts outreach letters.
4. Adds the masking and row access policies.
5. Creates the semantic view, the search service and the Cortex Agent.
6. Measures accuracy and deploys the Streamlit app.

It prints each file as it finishes and ends with `done in ...s`. It takes about 10 minutes,
most of it in `02_extract.sql` (reading the documents) and `08_cost_and_accuracy.sql`
(measuring accuracy).

If your account signs in through a browser (SSO), a sign-in tab opens when the script starts.
Finish signing in within a minute or so, or the script stops with
`Unable to receive the OAuth message within a given timeout`. Nothing is created when that
happens, so just run it again.

`--fresh` deletes the `ACME_EE` database first, so you always start clean. Leave it off if
you've changed anything in `ACME_EE` you want to keep. If you have several Snowflake accounts,
add `--expect-account <ACCOUNT_LOCATOR>` and the script stops before touching the wrong one.

### Step 8: Check that it worked

In a Snowsight SQL worksheet:

```sql
USE ROLE ACME_ENGINEER;
USE WAREHOUSE ACME_EE_WH;

-- Should return 16
SELECT COUNT(*) FROM ACME_EE.CORE.PROPERTY_ASSESSMENTS;

-- Accuracy by document format, compared against data/labels.csv
SELECT source_format, ROUND(100 * COUNT_IF(is_correct) / COUNT(*), 1) AS pct_correct
FROM ACME_EE.CORE.EXTRACTION_ACCURACY
GROUP BY source_format;
```

Your numbers may differ slightly from run to run, because the AI model's answers can vary.

### Step 9: Try the agent and the app

Open a SQL worksheet in Snowsight and run these. They work the same however the Snowsight menus
are arranged.

```sql
USE ROLE ACME_PROGRAM_MGR;
USE SECONDARY ROLES NONE;
USE WAREHOUSE ACME_EE_WH;

-- Ask the agent a question
SELECT TRY_PARSE_JSON(SNOWFLAKE.CORTEX.DATA_AGENT_RUN('ACME_EE.APP.EE_PROGRAM_AGENT',
  $${"messages":[{"role":"user","content":[{"type":"text",
     "text":"How many homes qualify for a heat pump conversion, by state?"}]}],"stream":false}$$)) AS answer;

-- Check the app exists
SHOW STREAMLITS IN SCHEMA ACME_EE.APP;

-- See what an analyst sees: only Massachusetts, owner names and house numbers hidden
USE ROLE ACME_ANALYST;
SELECT municipality, address, owner_name FROM ACME_EE.CORE.PROPERTY_ASSESSMENTS;
```

The agent's answer is in the `content` part of the result. It should say 7 homes: 4 in
Connecticut and 3 in Massachusetts.

To use them in Snowsight instead:

- **Switch role:** click your name in the bottom-left corner and pick the role.
- **The agent:** in the left menu, open **AI**, then **Agents**, and select `EE_PROGRAM_AGENT`.
- **The app:** in the left menu, open **Apps**, then **Streamlit**, and open
  `ACME home energy leads`. The **Ask** tab may not work inside Snowflake, because Cortex Agents
  can't be called from a Streamlit app on the warehouse runtime. It works when you run the app on
  your own computer (below).

Snowsight's menus change from time to time. If you can't find an item, use the search box at the
top of the left menu.

You can also run the app on your own computer:

```bash
SNOWFLAKE_CONNECTION=acme .venv/bin/streamlit run scripts/run_app_local.py
```

It opens in your browser. Put `APP_ROLE=ACME_ANALYST` in front of the command to see the app
as an analyst. If you built with your own names in step 7, also add `ACME_DATABASE=...`,
`ACME_WAREHOUSE=...` and `ACME_ROLE_PREFIX=...` with the same values.

### Step 10: Clean up when you're done

The warehouse suspends itself after a minute of inactivity, so leaving everything in place
costs almost nothing. To remove it all:

```sql
USE ROLE ACCOUNTADMIN;
DROP DATABASE IF EXISTS ACME_EE;
DROP WAREHOUSE IF EXISTS ACME_EE_WH;
DROP ROLE IF EXISTS ACME_PROGRAM_MGR;
DROP ROLE IF EXISTS ACME_ANALYST;
DROP ROLE IF EXISTS ACME_ENGINEER;
```

### If something goes wrong

| What you see | What to do |
|---|---|
| `Unknown function AI_EXTRACT` | AI functions aren't available to the role or in your region. Do step 4, then run step 7 again. |
| `Insufficient privileges` during setup | Your user can't use `ACCOUNTADMIN`. Ask an account admin to grant it, or to run step 7 for you. |
| `Incorrect username or password` or `account not found` | Check the `account` and `user` values in `connections.toml` (step 3). |
| `command not found: python3` | Install Python (step 1). On Windows, try `python` or `py` instead. |
| `No module named ...` | Use the `.venv/bin/python` commands exactly as written, after step 5. |
| `already exists` or a role you don't recognize | Another project uses the same names. Run step 7 again with `--database`, `--warehouse` and `--role-prefix`. |
| The agent says it can't find the data | Make sure your role is `ACME_PROGRAM_MGR`, not `ACCOUNTADMIN` or `ACME_ANALYST`. |

You can also run the SQL files in `sql/` by hand, in number order, in a Snowsight worksheet.
The `PUT` upload commands they need are in their comments, and those have to run from
SnowSQL or the Snowflake CLI, not from a worksheet.

## Measuring accuracy

`data/labels.csv` holds the right answer for every field in the 16 test documents.
`sql/08_cost_and_accuracy.sql` compares the model's output against it, shows accuracy by
format and by confidence score, and pulls cost from `ACCOUNT_USAGE`.

To try it at volume:

```bash
.venv/bin/python scripts/make_sample_docs.py --volume 500
```

This writes `data/volume/` (about 170 MB, so it isn't checked in) and `data/volume_labels.csv`.
Then follow the steps in `sql/10_volume_test.sql`.

## About the data

Two records come from public assessor data with the owner names changed. Everything else is
made up. The savings numbers in `DEEMED_SAVINGS` are placeholders; a real program should use
its state's Technical Reference Manual.
