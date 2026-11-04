-- ============================================================================
-- APEX FITNESS & WELLNESS TRACKING SYSTEM
-- DATABASE STRESS TEST & QUERY OPTIMIZATION BENCHMARK
-- Target: 5,000+ entries, EXPLAIN ANALYZE execution profiling
-- ============================================================================

USE fitness_wellness;

-- ----------------------------------------------------------------------------
-- STEP 1: VERIFY CURRENT VOLUME & RUN STRESS GENERATOR
-- ----------------------------------------------------------------------------
SELECT 'Initial Table Row Counts' AS benchmark_stage,
       (SELECT COUNT(*) FROM users) AS users_count,
       (SELECT COUNT(*) FROM workout_sessions) AS workout_sessions_count,
       (SELECT COUNT(*) FROM workout_exercises) AS workout_exercises_count,
       (SELECT COUNT(*) FROM nutrition_logs) AS nutrition_logs_count,
       (SELECT COUNT(*) FROM health_metrics) AS health_metrics_count;

-- Generate 5,000 synthetic, realistic nutrition logs across all 20 users
CALL sp_generate_stress_data(5000);

SELECT 'Post-Stress Table Row Counts' AS benchmark_stage,
       (SELECT COUNT(*) FROM nutrition_logs) AS total_nutrition_logs_after_stress;


-- ----------------------------------------------------------------------------
-- STEP 2: BENCHMARK ANALYTICAL QUERIES WITH EXPLAIN ANALYZE (BEFORE NEW INDEXES)
-- ----------------------------------------------------------------------------

-- Benchmark Query 1: Daily Nutrition Summary (Aggregates 5,000+ rows)
EXPLAIN ANALYZE
SELECT user_id, log_date, ROUND(calories) calories, ROUND(protein_g,1) protein, ROUND(carbs_g,1) carbs, ROUND(fat_g,1) fat
FROM v_daily_nutrition
ORDER BY log_date DESC, user_id;

-- Benchmark Query 2: Calorie Balance Per User Per Day (Complex UNION + Double LEFT JOIN)
EXPLAIN ANALYZE
SELECT u.full_name, d.activity_date AS log_date,
       COALESCE(ROUND(n.calories), 0) AS consumed,
       COALESCE(w.burned, 0) AS burned,
       COALESCE(ROUND(n.calories), 0) - COALESCE(w.burned, 0) AS balance
FROM (
    SELECT user_id, log_date AS activity_date FROM v_daily_nutrition
    UNION
    SELECT user_id, workout_date AS activity_date FROM workout_sessions
) d
JOIN users u USING (user_id)
LEFT JOIN v_daily_nutrition n ON n.user_id = d.user_id AND n.log_date = d.activity_date
LEFT JOIN (
    SELECT user_id, workout_date, SUM(calories_burned) AS burned
    FROM workout_sessions
    GROUP BY user_id, workout_date
) w ON w.user_id = d.user_id AND w.workout_date = d.activity_date
ORDER BY d.activity_date DESC;

-- Benchmark Query 3: Weekly Progress Report (Windowing / Aggregation)
EXPLAIN ANALYZE
SELECT u.full_name, YEARWEEK(ws.workout_date,1) AS yr_week, COUNT(*) AS total_workouts,
       SUM(TIMESTAMPDIFF(MINUTE,ws.start_time,ws.end_time)) AS total_minutes, SUM(ws.calories_burned) AS calories_burned
FROM workout_sessions ws JOIN users u USING (user_id)
GROUP BY u.user_id, u.full_name, yr_week ORDER BY yr_week DESC, calories_burned DESC;

-- Benchmark Query 4: Health Risk & Trends (Window Functions over Time-Series)
EXPLAIN ANALYZE
SELECT full_name, record_datetime, weight_kg, bmi, steps, sleep_hours,
       ROUND(weight_kg - LAG(weight_kg) OVER w, 2) AS weight_change,
       ROUND(bmi - LAG(bmi) OVER w, 2) AS bmi_change
FROM v_health_metrics_bmi WINDOW w AS (PARTITION BY user_id ORDER BY record_datetime);


-- ----------------------------------------------------------------------------
-- STEP 3: APPLY TARGETED INDEX OPTIMIZATIONS
-- ----------------------------------------------------------------------------
-- Recommended Index 1: Covering composite index on nutrition_logs to eliminate table scans
-- during v_daily_nutrition aggregation:
CREATE INDEX idx_nl_user_date_cals ON nutrition_logs(user_id, log_date, food_id, quantity, total_calories);

-- Recommended Index 2: Composite index on workout_sessions for fast date range & grouping:
CREATE INDEX idx_ws_user_date_burn ON workout_sessions(user_id, workout_date, calories_burned);


-- ----------------------------------------------------------------------------
-- STEP 4: RE-RUN EXPLAIN ANALYZE TO CONFIRM OPTIMIZATION
-- ----------------------------------------------------------------------------
EXPLAIN ANALYZE
SELECT user_id, log_date, ROUND(calories) calories, ROUND(protein_g,1) protein, ROUND(carbs_g,1) carbs, ROUND(fat_g,1) fat
FROM v_daily_nutrition
ORDER BY log_date DESC, user_id;

EXPLAIN ANALYZE
SELECT u.full_name, d.activity_date AS log_date,
       COALESCE(ROUND(n.calories), 0) AS consumed,
       COALESCE(w.burned, 0) AS burned,
       COALESCE(ROUND(n.calories), 0) - COALESCE(w.burned, 0) AS balance
FROM (
    SELECT user_id, log_date AS activity_date FROM v_daily_nutrition
    UNION
    SELECT user_id, workout_date AS activity_date FROM workout_sessions
) d
JOIN users u USING (user_id)
LEFT JOIN v_daily_nutrition n ON n.user_id = d.user_id AND n.log_date = d.activity_date
LEFT JOIN (
    SELECT user_id, workout_date, SUM(calories_burned) AS burned
    FROM workout_sessions
    GROUP BY user_id, workout_date
) w ON w.user_id = d.user_id AND w.workout_date = d.activity_date
ORDER BY d.activity_date DESC;

SELECT 'Stress testing and index optimization completed successfully.' AS status;
