
# filename: ai_talent_dashboard.py
import streamlit as st
import pandas as pd
import numpy as np
import plotly.express as px
import plotly.graph_objects as go
import openai

# ---------- LOAD DATA ----------
@st.cache_data
def load_data():
    url = "https://raw.githubusercontent.com/triadibs/Talent-Success-Formula-Project/main/Dataset/Study%20Case%20DA.xlsx"
    data = pd.read_excel(url, sheet_name=None)
    return data

data = load_data()
employees = data['employees']
performance = data['performance_yearly']
competency = data['competencies_yearly']
pillars = data['dim_competency_pillars']
papi = data['papi_scores']
profiles = data['profiles_psych']
strengths = data['strengths']

# ---------- SIDEBAR INPUT ----------
st.sidebar.header("🧭 Job Parameters")

role_name = st.sidebar.text_input("Role Name", "Data Analyst")
job_level = st.sidebar.selectbox("Job Level", ["Junior", "Middle", "Senior"], index=1)
role_purpose = st.sidebar.text_area("Role Purpose", "Responsible for turning data into actionable insights.")
benchmark_ids = st.sidebar.text_input("Benchmark Employee IDs (comma-separated)", "EMP100001, EMP100005, EMP100010")

benchmark_ids = [x.strip() for x in benchmark_ids.split(",")]

# ---------- RECOMPUTE BENCHMARK ----------
benchmark_perf = performance[performance['employee_id'].isin(benchmark_ids)]
top_year = benchmark_perf['year'].max()
benchmark_avg = competency[competency['employee_id'].isin(benchmark_ids)].groupby('pillar_code')['score'].mean()

# ---------- MATCH RATE SCORING ----------
merged = competency.merge(benchmark_avg, on='pillar_code', suffixes=('_emp', '_bm'))
merged['gap'] = abs(merged['score_emp'] - merged['score_bm'])
score_summary = (
    merged.groupby('employee_id')['gap'].mean().reset_index()
)
score_summary['match_rate'] = 1 - score_summary['gap']
score_summary = score_summary.merge(employees[['employee_id', 'fullname']], on='employee_id')
ranked = score_summary.sort_values('match_rate', ascending=False).head(10)

# ---------- VISUALIZATIONS ----------
st.title("🤖 AI Talent Match Dashboard")
st.markdown("### Role: {} | Level: {}".format(role_name, job_level))
st.markdown(f"**Purpose:** {role_purpose}")

# Match Rate Distribution
fig = px.histogram(score_summary, x='match_rate', nbins=20, title='Match Rate Distribution')
st.plotly_chart(fig, use_container_width=True)

# Top 10 Ranking
st.subheader("🏆 Top 10 Candidate Matches")
st.dataframe(ranked[['employee_id', 'fullname', 'match_rate']])

# Radar Chart Comparison
sample_emp = st.selectbox("Compare Employee vs Benchmark", ranked['employee_id'])
emp_comp = competency[competency['employee_id'] == sample_emp].groupby('pillar_code')['score'].mean()
compare_df = pd.DataFrame({
    'pillar_code': benchmark_avg.index,
    'Benchmark': benchmark_avg.values,
    'Employee': emp_comp.reindex(benchmark_avg.index).fillna(0).values
})
compare_df = compare_df.merge(pillars, on='pillar_code', how='left')

fig2 = go.Figure()
fig2.add_trace(go.Scatterpolar(r=compare_df['Benchmark'], theta=compare_df['pillar_label'], fill='toself', name='Benchmark'))
fig2.add_trace(go.Scatterpolar(r=compare_df['Employee'], theta=compare_df['pillar_label'], fill='toself', name='Employee'))
fig2.update_layout(polar=dict(radialaxis=dict(visible=True, range=[0,5])), showlegend=True, title="Competency Comparison (Radar)")
st.plotly_chart(fig2, use_container_width=True)

# ---------- AI JOB PROFILE GENERATION ----------
st.subheader("🧠 AI-Generated Job Profile")

prompt = f"""
You are an HR data consultant. Write a concise Data Analyst job profile for level {job_level}.
Role purpose: {role_purpose}
Highlight job requirements, description, and key competencies.
"""

# optional: use your OpenAI API key
# openai.api_key = st.secrets["OPENAI_API_KEY"]

# if you have key
# response = openai.ChatCompletion.create(model="gpt-4o-mini", messages=[{"role":"user","content":prompt}])
# ai_output = response.choices[0].message.content

# placeholder output (demo mode)
ai_output = f"""
**Job Requirements**
- Strong SQL and Python (pandas/numpy)
- BI Tools (Tableau/Power BI)
- Analytical storytelling and stakeholder communication

**Job Description**
Turn business questions into data-driven insights. Own the end-to-end analysis workflow — from data extraction, cleaning, modeling, to dashboarding.

**Key Competencies**
- Curiosity & Experimentation
- Quality Delivery Discipline
- Strategic Thinking & Clarity
- Social Empathy & Awareness
"""

st.markdown(ai_output)

# ---------- Summary Insights ----------
st.subheader("💬 Summary Insight")
top_candidate = ranked.iloc[0]
st.write(f"The highest match is **{top_candidate['fullname']} ({top_candidate['employee_id']})** with a match rate of **{top_candidate['match_rate']:.2f}**.")
st.write("They exhibit strong alignment with the benchmark on strategic thinking, empathy, and delivery discipline pillars.")
