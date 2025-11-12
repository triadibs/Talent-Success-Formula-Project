-- ============================================================
-- PROJECT: Talent Match Engine
-- PURPOSE: Menghitung kesesuaian karyawan dengan benchmark profil ideal
-- AUTHOR : Tri Adi Baskoro
-- PHASE  : Deliverable #2 – SQL Logic & Algorithm
-- DATABASE: Supabase (PostgreSQL)
-- ============================================================


-- ============================================================
-- SECTION 1: MASTER TABLE DEFINITIONS
-- ============================================================

-- 1.1 Employee Talent Variables (TVs)
CREATE TABLE IF NOT EXISTS employee_tvs (
  employee_id TEXT,
  tv_name TEXT,
  user_score NUMERIC,
  PRIMARY KEY (employee_id, tv_name)
);

-- 1.2 Talent Variable Catalog
CREATE TABLE IF NOT EXISTS tv_catalog (
  tv_name TEXT PRIMARY KEY,
  tgv_name TEXT,
  value_type TEXT,           -- 'numeric' atau 'categorical'
  lower_is_better BOOLEAN DEFAULT FALSE
);

-- 1.3 Talent Benchmark Configuration
CREATE TABLE IF NOT EXISTS talent_benchmarks (
  job_vacancy_id INT PRIMARY KEY,
  role_name TEXT,
  job_level TEXT,
  role_purpose TEXT,
  summary TEXT,
  selected_talent_ids TEXT[],    -- array of employee_id
  weights_config JSONB           -- optional: { "tv_weights": {...}, "tgv_weights": {...} }
);



-- ============================================================
-- SECTION 2: POPULATE EMPLOYEE_TVS
-- Mengkonsolidasi seluruh sumber asesmen menjadi satu format standar
-- ============================================================

-- 2.1 Kompetensi Tahunan
INSERT INTO employee_tvs (employee_id, tv_name, user_score)
SELECT employee_id, LOWER(pillar_code) AS tv_name, AVG(score)::NUMERIC
FROM competencies_yearly
WHERE score IS NOT NULL
GROUP BY employee_id, pillar_code
ON CONFLICT (employee_id, tv_name) DO NOTHING;

-- 2.2 PAPI Scales
INSERT INTO employee_tvs (employee_id, tv_name, user_score)
SELECT employee_id, LOWER(scale_code), AVG(score)::NUMERIC
FROM papi_scores
WHERE score IS NOT NULL
GROUP BY employee_id, scale_code
ON CONFLICT (employee_id, tv_name) DO NOTHING;

-- 2.3 Psikometri (IQ, Faxtor, Pauli, GTQ, TIKI)
INSERT INTO employee_tvs (employee_id, tv_name, user_score)
SELECT employee_id, 'iq', iq FROM profiles_psych WHERE iq IS NOT NULL
ON CONFLICT (employee_id, tv_name) DO NOTHING;

INSERT INTO employee_tvs (employee_id, tv_name, user_score)
SELECT employee_id, 'faxtor', faxtor FROM profiles_psych WHERE faxtor IS NOT NULL
ON CONFLICT (employee_id, tv_name) DO NOTHING;

INSERT INTO employee_tvs (employee_id, tv_name, user_score)
SELECT employee_id, 'pauli', pauli FROM profiles_psych WHERE pauli IS NOT NULL
ON CONFLICT (employee_id, tv_name) DO NOTHING;

INSERT INTO employee_tvs (employee_id, tv_name, user_score)
SELECT employee_id, 'gtq', gtq FROM profiles_psych WHERE gtq IS NOT NULL
ON CONFLICT (employee_id, tv_name) DO NOTHING;

INSERT INTO employee_tvs (employee_id, tv_name, user_score)
SELECT employee_id, 'tiki', tiki FROM profiles_psych WHERE tiki IS NOT NULL
ON CONFLICT (employee_id, tv_name) DO NOTHING;

-- 2.4 Strengths Ranking (dibalik agar rank 1 = skor tinggi)
INSERT INTO employee_tvs (employee_id, tv_name, user_score)
SELECT employee_id, LOWER(theme) AS tv_name, (15 - rank)::NUMERIC AS user_score
FROM strengths
WHERE rank <= 5 AND theme IS NOT NULL AND TRIM(theme) <> ''
ON CONFLICT (employee_id, tv_name) DO NOTHING;

-- 2.5 Data Karyawan (grade, pendidikan, masa kerja)
INSERT INTO employee_tvs (employee_id, tv_name, user_score)
SELECT employee_id, 'grade_name', grade_id::NUMERIC
FROM employees WHERE grade_id IS NOT NULL
ON CONFLICT (employee_id, tv_name)
DO UPDATE SET user_score = EXCLUDED.user_score;

INSERT INTO employee_tvs (employee_id, tv_name, user_score)
SELECT employee_id, 'education_level', education_id::NUMERIC
FROM employees WHERE education_id IS NOT NULL
ON CONFLICT (employee_id, tv_name)
DO UPDATE SET user_score = EXCLUDED.user_score;

INSERT INTO employee_tvs (employee_id, tv_name, user_score)
SELECT employee_id, 'years_of_service_months', years_of_service_months::NUMERIC
FROM employees WHERE years_of_service_months IS NOT NULL
ON CONFLICT (employee_id, tv_name)
DO UPDATE SET user_score = EXCLUDED.user_score;



-- ============================================================
-- SECTION 3: TV ? TGV CATALOG MAPPING
-- Mengelompokkan TV ke dalam domain kompetensi (TGV)
-- ============================================================

INSERT INTO tv_catalog (tv_name, tgv_name, value_type, lower_is_better)
VALUES
('sea','teamwork','numeric',FALSE),
('qdd','technical_expertise','numeric',FALSE),
('ftc','leadership','numeric',FALSE),
('papi_o','personality','numeric',FALSE),
('papi_p','personality','numeric',FALSE),
('papi_n','personality','numeric',FALSE),
('faxtor','cognitive_ability','numeric',FALSE),
('gtq','cognitive_ability','numeric',FALSE),
('tiki','cognitive_ability','numeric',FALSE),
('futuristic','leadership','numeric',FALSE),
('responsibility','teamwork','numeric',FALSE),
('focus','cognitive_ability','numeric',FALSE),
('relator','teamwork','numeric',FALSE),
('grade_name','technical_expertise','numeric',FALSE),
('education_level','technical_expertise','numeric',FALSE),
('years_of_service_months','leadership','numeric',FALSE)
ON CONFLICT (tv_name) DO NOTHING;



-- ============================================================
-- SECTION 4: CORE FUNCTION – COMPUTE_TALENT_MATCH
-- ============================================================

CREATE OR REPLACE FUNCTION compute_talent_match(_job_vacancy_id INT)
RETURNS TABLE (
  employee_id TEXT,
  directorate TEXT,
  position_title TEXT,
  grade TEXT,
  tgv_name TEXT,
  tv_name TEXT,
  baseline_score NUMERIC,
  user_score NUMERIC,
  tv_match_rate NUMERIC,
  tgv_match_rate NUMERIC,
  final_match_rate NUMERIC
) AS
$$
WITH
input_benchmark AS (
  SELECT * FROM talent_benchmarks WHERE job_vacancy_id = _job_vacancy_id
),
benchmark_members AS (
  SELECT UNNEST(selected_talent_ids) AS employee_id FROM input_benchmark
),
tv_baseline AS (
  SELECT et.tv_name,
         PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY et.user_score) AS baseline_score
  FROM employee_tvs et
  JOIN benchmark_members bm ON et.employee_id = bm.employee_id
  GROUP BY et.tv_name
),
tv_meta AS (
  SELECT b.tv_name, b.baseline_score, c.tgv_name, c.value_type, COALESCE(c.lower_is_better, FALSE) AS lower_is_better
  FROM tv_baseline b
  LEFT JOIN tv_catalog c USING(tv_name)
),
all_employee_tv AS (
  SELECT 
    e.employee_id,
    d.name AS directorate,
    p.name AS position_title,
    g.name AS grade,
    tv.tv_name,
    et.user_score
  FROM employees e
  LEFT JOIN dim_directorates d ON e.directorate_id = d.directorate_id
  LEFT JOIN dim_positions p ON e.position_id = p.position_id
  LEFT JOIN dim_grades g ON e.grade_id = g.grade_id
  CROSS JOIN (SELECT tv_name FROM tv_baseline) tv
  LEFT JOIN employee_tvs et ON et.employee_id = e.employee_id AND et.tv_name = tv.tv_name
),
tv_match_raw AS (
  SELECT
    a.employee_id, a.directorate, a.position_title, a.grade,
    m.tgv_name, m.tv_name, m.baseline_score, a.user_score, m.value_type, m.lower_is_better,
    CASE
      WHEN m.value_type = 'numeric' AND m.baseline_score IS NOT NULL THEN
        CASE
          WHEN NOT m.lower_is_better THEN LEAST((COALESCE(a.user_score,0) / NULLIF(m.baseline_score,0)) * 100.0, 100.0)
          ELSE LEAST(((2 * m.baseline_score - COALESCE(a.user_score, m.baseline_score)) / NULLIF(m.baseline_score,0)) * 100.0, 100.0)
        END
      WHEN m.value_type = 'categorical' THEN 
        CASE WHEN a.user_score::TEXT = m.baseline_score::TEXT THEN 100.0 ELSE 0.0 END
      ELSE 0.0
    END AS tv_match_rate
  FROM all_employee_tv a
  LEFT JOIN tv_meta m USING (tv_name)
),
config_tv_weights AS (
  SELECT (kv).key AS tv_name, (kv).value::NUMERIC AS tv_weight
  FROM input_benchmark ib, JSONB_EACH_TEXT(ib.weights_config -> 'tv_weights') AS kv
),
config_tgv_weights AS (
  SELECT (kv).key AS tgv_name, (kv).value::NUMERIC AS tgv_weight
  FROM input_benchmark ib, JSONB_EACH_TEXT(ib.weights_config -> 'tgv_weights') AS kv
),
tv_list AS (
  SELECT DISTINCT c.tv_name, COALESCE(c.tgv_name,'ungrouped') AS tgv_name
  FROM tv_catalog c
  JOIN tv_baseline b USING (tv_name)
),
tvs_per_tgv AS (
  SELECT tgv_name, COUNT(*) AS tv_count FROM tv_list GROUP BY tgv_name
),
num_tgvs AS (
  SELECT COUNT(DISTINCT tgv_name) AS n_tgvs FROM tv_list
),
tgv_default AS (
  SELECT t.tgv_name,
         COALESCE(ct.tgv_weight, 1.0 / GREATEST(nt.n_tgvs,1)) AS tgv_weight
  FROM (SELECT DISTINCT tgv_name FROM tv_list) t
  LEFT JOIN config_tgv_weights ct ON ct.tgv_name = t.tgv_name
  CROSS JOIN num_tgvs nt
),
tv_weights AS (
  SELECT
    tv.tv_name,
    tv.tgv_name,
    COALESCE(ctw.tv_weight, td.tgv_weight / GREATEST(tp.tv_count,1)) AS final_tv_weight,
    td.tgv_weight
  FROM tv_list tv
  LEFT JOIN config_tv_weights ctw ON ctw.tv_name = tv.tv_name
  LEFT JOIN tvs_per_tgv tp ON tp.tgv_name = tv.tgv_name
  LEFT JOIN tgv_default td ON td.tgv_name = tv.tgv_name
),
tv_with_weights AS (
  SELECT tmr.*, COALESCE(tw.final_tv_weight,0) AS tv_weight
  FROM tv_match_raw tmr
  LEFT JOIN tv_weights tw USING (tv_name)
),
tgv_aggregate AS (
  SELECT employee_id, tgv_name,
    CASE WHEN SUM(tv_weight) > 0 THEN SUM(tv_match_rate * tv_weight) / SUM(tv_weight) ELSE NULL END AS tgv_match_rate
  FROM tv_with_weights
  GROUP BY employee_id, tgv_name
),
tgv_weights_final AS (
  SELECT tgv_name, tgv_weight FROM tgv_default
),
final_match AS (
  SELECT a.employee_id,
    CASE WHEN SUM(tw.tgv_weight) > 0 THEN SUM(a.tgv_match_rate * tw.tgv_weight) / SUM(tw.tgv_weight) ELSE NULL END AS final_match_rate
  FROM tgv_aggregate a
  LEFT JOIN tgv_weights_final tw ON tw.tgv_name = a.tgv_name
  GROUP BY a.employee_id
)

SELECT
  t.employee_id,
  t.directorate,
  t.position_title,
  t.grade,
  t.tgv_name,
  t.tv_name,
  t.baseline_score,
  t.user_score,
  t.tv_match_rate,
  a.tgv_match_rate,
  f.final_match_rate
FROM tv_with_weights t
LEFT JOIN tgv_aggregate a ON a.employee_id = t.employee_id AND a.tgv_name = t.tgv_name
LEFT JOIN final_match f ON f.employee_id = t.employee_id
ORDER BY f.final_match_rate DESC NULLS LAST, a.tgv_match_rate DESC NULLS LAST, t.tv_name;
$$ LANGUAGE sql STABLE;



-- ============================================================
-- SECTION 5: BENCHMARK CREATION & VALIDATION
-- ============================================================

-- 5.1 Buat benchmark otomatis dari semua karyawan dengan rating = 5
INSERT INTO talent_benchmarks (
  job_vacancy_id, role_name, job_level, role_purpose, summary, selected_talent_ids, weights_config
)
VALUES (
  1,
  'Auto - Benchmark from rating 5',
  'auto',
  'Benchmark dari semua employee dengan kinerja tertinggi',
  'Generated from performance_yearly where rating = 5',
  (SELECT ARRAY_AGG(DISTINCT employee_id) FROM performance_yearly WHERE rating = 5),
  '{}'::JSONB
);

-- 5.2 Jalankan fungsi untuk menghasilkan hasil kecocokan
SELECT * FROM compute_talent_match(1) LIMIT 200;

-- 5.3 Validasi distribusi hasil match per rating kinerja
WITH fm AS (SELECT employee_id, final_match_rate FROM compute_talent_match(1))
SELECT p.rating, COUNT(*) AS n, AVG(fm.final_match_rate) AS avg_match
FROM performance_yearly p
JOIN fm ON p.employee_id = fm.employee_id
GROUP BY p.rating
ORDER BY p.rating;
