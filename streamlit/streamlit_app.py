import json

import pandas as pd
import streamlit as st
from snowflake.snowpark.context import get_active_session

st.set_page_config(page_title="ACME home energy leads", layout="wide")

AGENT = "ACME_EE.APP.EE_PROGRAM_AGENT"
session = get_active_session()


@st.cache_data(ttl=300)
def q(sql: str, params: tuple = ()) -> pd.DataFrame:
    return session.sql(sql, params=list(params)).to_pandas()


st.title("ACME home energy leads")
st.caption("Property data read from municipal assessor records with Snowflake AI_EXTRACT. "
           "Savings figures are illustrative, not TRM values.")

pipeline, targeting, review, ask = st.tabs(["Pipeline", "Targeting", "Review queue", "Ask"])

with pipeline:
    status = q("""
        SELECT (SELECT COUNT(*) FROM DIRECTORY(@ACME_EE.RAW.ASSESSOR_DOCS)) AS docs_on_stage,
               (SELECT COUNT(*) FROM ACME_EE.RAW.EXTRACTIONS)               AS docs_extracted,
               (SELECT COUNT(*) FROM ACME_EE.CORE.PROPERTY_ASSESSMENTS)     AS homes,
               (SELECT COUNT(*) FROM ACME_EE.CORE.REVIEW_QUEUE WHERE status = 'open') AS open_reviews
    """).iloc[0]
    c1, c2, c3, c4 = st.columns(4)
    c1.metric("Documents on stage", int(status.DOCS_ON_STAGE))
    c2.metric("Documents extracted", int(status.DOCS_EXTRACTED))
    c3.metric("Homes in table", int(status.HOMES))
    c4.metric("Fields waiting for review", int(status.OPEN_REVIEWS))

    st.subheader("Lowest-confidence field per document")
    st.dataframe(q("""
        SELECT municipality, parcel_id, source_file, ROUND(min_field_score, 2) AS min_score, updated_at
        FROM ACME_EE.CORE.PROPERTY_ASSESSMENTS ORDER BY min_field_score
    """), hide_index=True, use_container_width=True)

with targeting:
    recs = q("SELECT * FROM ACME_EE.CORE.PROGRAM_RECOMMENDATIONS")
    measures = st.multiselect("Measure", sorted(recs.MEASURE.unique()),
                              default=sorted(recs.MEASURE.unique()))
    lmi_only = st.toggle("LMI pre-screen only")
    view = recs[recs.MEASURE.isin(measures)]
    if lmi_only:
        view = view[view.LMI_PRESCREEN]

    c1, c2, c3, c4 = st.columns(4)
    c1.metric("Leads", len(view))
    c2.metric("Therms / yr", f"{view.EST_THERMS_SAVED.fillna(0).sum():,.0f}")
    c3.metric("Gallons / yr", f"{view.EST_GALLONS_SAVED.fillna(0).sum():,.0f}")
    c4.metric("kWh / yr", f"{view.EST_KWH_SAVED.fillna(0).sum():,.0f}",
              help="Negative means added electric load from fuel switching")

    st.bar_chart(view.groupby(["MUNICIPALITY", "MEASURE"]).size().rename("leads").reset_index(),
                 x="MUNICIPALITY", y="leads", color="MEASURE")
    st.dataframe(view[["MUNICIPALITY", "ADDRESS", "OWNER_NAME", "DWELLING_STYLE", "YEAR_BUILT",
                       "HEATING_FUEL", "MEASURE", "REASON", "EST_THERMS_SAVED",
                       "EST_GALLONS_SAVED", "EST_KWH_SAVED", "LMI_PRESCREEN"]],
                 hide_index=True, use_container_width=True)

    st.subheader("Draft outreach letters")
    letters = q("SELECT municipality, parcel_id, measure, letter, status FROM ACME_EE.CORE.OUTREACH_DRAFTS")
    for row in letters.itertuples():
        with st.expander(f"{row.MUNICIPALITY} · {row.PARCEL_ID} · {row.MEASURE} ({row.STATUS})"):
            st.write(row.LETTER)

with review:
    st.write("Fields the model was less sure about (score under 0.8), plus blanks on fields we target on.")
    queue = q("""
        SELECT file_name, municipality, parcel_id, field_name, extracted_value,
               ROUND(score, 2) AS score, corrected_value
        FROM ACME_EE.CORE.REVIEW_QUEUE WHERE status = 'open' ORDER BY score
    """)
    edited = st.data_editor(queue, hide_index=True, use_container_width=True,
                            disabled=[c for c in queue.columns if c != "CORRECTED_VALUE"])
    if st.button("Save reviewed rows", type="primary"):
        done = edited[edited.CORRECTED_VALUE.notna() & (edited.CORRECTED_VALUE != "")]
        for r in done.itertuples():
            session.sql("""
                UPDATE ACME_EE.CORE.REVIEW_QUEUE
                SET corrected_value = ?, status = 'reviewed', reviewed_by = CURRENT_USER(),
                    reviewed_at = CURRENT_TIMESTAMP()
                WHERE file_name = ? AND field_name = ?
            """, params=[r.CORRECTED_VALUE, r.FILE_NAME, r.FIELD_NAME]).collect()
        # Push the corrections into the property table, leads, and agent now.
        if len(done):
            session.sql("CALL ACME_EE.CORE.REFRESH_PROPERTIES()").collect()
        st.cache_data.clear()
        st.success(f"Saved {len(done)} field(s).")

with ask:
    question = st.chat_input("Ask about homes, measures, or what a property card says")
    if question:
        st.chat_message("user").write(question)
        body = json.dumps({"messages": [{"role": "user", "content": [{"type": "text", "text": question}]}],
                           "stream": False})
        with st.spinner("Thinking..."):
            raw = session.sql("SELECT SNOWFLAKE.CORTEX.DATA_AGENT_RUN(?, ?) AS r",
                              params=[AGENT, body]).collect()[0]["R"]
        reply = json.loads(raw)
        with st.chat_message("assistant"):
            for item in reply.get("content", []):
                if item.get("type") == "text":
                    st.markdown(item["text"])
                elif item.get("type") == "table":
                    rs = item["table"]["result_set"]
                    cols = [c["name"] for c in rs["resultSetMetaData"]["rowType"]]
                    st.dataframe(pd.DataFrame(rs["data"], columns=cols), hide_index=True)
                elif item.get("type") == "tool_use":
                    st.caption(f"Used tool: {item['tool_use']['name']}")
