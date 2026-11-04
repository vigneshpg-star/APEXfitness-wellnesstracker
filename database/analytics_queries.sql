USE fitness_wellness;

-- 1. Weekly workout summary (JOIN + SUM + GROUP BY)
SELECT u.full_name, YEARWEEK(ws.workout_date,1) AS yr_week, COUNT(*) AS total_workouts,
       SUM(TIMESTAMPDIFF(MINUTE,ws.start_time,ws.end_time)) AS total_minutes, SUM(ws.calories_burned) AS calories_burned
FROM workout_sessions ws JOIN users u USING (user_id)
GROUP BY u.user_id, u.full_name, yr_week ORDER BY yr_week DESC, calories_burned DESC;

-- 2. Daily nutrition summary
SELECT user_id, log_date, ROUND(calories) calories, ROUND(protein_g,1) protein, ROUND(carbs_g,1) carbs, ROUND(fat_g,1) fat
FROM v_daily_nutrition ORDER BY log_date DESC, user_id;

-- 3. Calorie balance per user per day (consumed - workout burn)
SELECT u.full_name, d.activity_date AS log_date,
       COALESCE(ROUND(n.calories), 0) AS consumed,
       COALESCE(w.burned, 0) AS burned,
       COALESCE(ROUND(n.calories), 0) - COALESCE(w.burned, 0) AS balance,
       CASE WHEN COALESCE(ROUND(n.calories), 0) - COALESCE(w.burned, 0) < 0 THEN 'Deficit' ELSE 'Surplus' END AS status
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

-- 4. Progress tracking: change vs previous record (window functions)
SELECT full_name, record_datetime, weight_kg, bmi, steps, sleep_hours,
       ROUND(weight_kg - LAG(weight_kg) OVER w, 2) AS weight_change,
       ROUND(bmi - LAG(bmi) OVER w, 2) AS bmi_change,
       steps - LAG(steps) OVER w AS steps_change,
       ROUND(sleep_hours - LAG(sleep_hours) OVER w, 2) AS sleep_change
FROM v_health_metrics_bmi WINDOW w AS (PARTITION BY user_id ORDER BY record_datetime);

-- 5. Protein intake vs workout activity (pre-aggregated to avoid join fan-out)
SELECT u.full_name, ROUND(p.avg_protein,1) avg_daily_protein, COALESCE(w.workouts,0) workouts,
       COALESCE(w.avg_burn,0) avg_burn_per_workout
FROM users u
JOIN (SELECT user_id, AVG(protein_g) avg_protein FROM v_daily_nutrition GROUP BY user_id) p USING (user_id)
LEFT JOIN (SELECT user_id, COUNT(*) workouts, ROUND(AVG(calories_burned)) avg_burn
           FROM workout_sessions GROUP BY user_id) w USING (user_id)
ORDER BY avg_daily_protein DESC;

-- 6. Most popular exercises
SELECT e.exercise_name, COUNT(*) AS times_performed
FROM workout_exercises we JOIN exercises e USING (exercise_id)
GROUP BY e.exercise_id, e.exercise_name ORDER BY times_performed DESC;

-- 7. Active users in the last 30 days
SELECT u.user_id, u.full_name FROM users u
WHERE EXISTS (SELECT 1 FROM workout_sessions w WHERE w.user_id=u.user_id AND w.workout_date >= CURDATE() - INTERVAL 30 DAY)
   OR EXISTS (SELECT 1 FROM nutrition_logs n WHERE n.user_id=u.user_id AND n.log_date   >= CURDATE() - INTERVAL 30 DAY);

-- 8. Health risk validation (CASE)
SELECT full_name, record_datetime, heart_rate, sleep_hours, weight_kg,
  CASE WHEN heart_rate > 150 THEN 'Very high heart rate'
       WHEN sleep_hours < 4 THEN 'Very low sleep'
       WHEN ABS(weight_kg - LAG(weight_kg) OVER (PARTITION BY user_id ORDER BY record_datetime)) > 3 THEN 'Unusual weight change'
       ELSE 'OK' END AS flag
FROM v_health_metrics_bmi;

-- 9. Advanced join: users + workouts + nutrition + health metrics
SELECT u.full_name, COALESCE(w.sessions,0) sessions, COALESCE(n.avg_cal,0) avg_daily_calories,
       h.avg_weight, h.avg_sleep
FROM users u
LEFT JOIN (SELECT user_id, COUNT(*) sessions FROM workout_sessions GROUP BY user_id) w USING (user_id)
LEFT JOIN (SELECT user_id, ROUND(AVG(calories)) avg_cal FROM v_daily_nutrition GROUP BY user_id) n USING (user_id)
LEFT JOIN (SELECT user_id, ROUND(AVG(weight_kg),1) avg_weight, ROUND(AVG(sleep_hours),1) avg_sleep
           FROM health_metrics GROUP BY user_id) h USING (user_id);

-- 10. Subquery: users whose average daily protein exceeds the overall average
SELECT u.full_name, ROUND(AVG(d.protein_g),1) avg_protein
FROM v_daily_nutrition d JOIN users u USING (user_id)
GROUP BY u.user_id, u.full_name
HAVING AVG(d.protein_g) > (SELECT AVG(protein_g) FROM v_daily_nutrition);

-- 11. Heart rate zones: readings per zone for every member (zone = % of max HR, max HR = 220 - age)
SELECT full_name, hr_zone, COUNT(*) AS readings, ROUND(AVG(heart_rate)) AS avg_hr, ROUND(AVG(pct_of_max),1) AS avg_pct_of_max
FROM v_heart_rate_zones
GROUP BY user_id, full_name, hr_zone
ORDER BY full_name, hr_zone;

-- 11b. Every individual reading with its zone
SELECT full_name, record_datetime, heart_rate, max_hr, pct_of_max, hr_zone
FROM v_heart_rate_zones ORDER BY full_name, record_datetime;

-- 12. Macronutrient ratios: daily split of calories (protein / carbs / fat) per member
SELECT u.full_name, m.log_date, m.calories, m.protein_pct, m.carbs_pct, m.fat_pct
FROM v_macro_ratios m JOIN users u USING (user_id)
ORDER BY u.full_name, m.log_date DESC;

-- 12b. Average macronutrient ratio per member
SELECT u.full_name, ROUND(AVG(m.protein_pct),1) AS avg_protein_pct, ROUND(AVG(m.carbs_pct),1) AS avg_carbs_pct, ROUND(AVG(m.fat_pct),1) AS avg_fat_pct
FROM v_macro_ratios m JOIN users u USING (user_id)
GROUP BY u.user_id, u.full_name ORDER BY u.full_name;

-- 13. Strength gains vs protein intake (weekly lifting volume change against average daily protein)
SELECT full_name, yr_week, avg_daily_protein_g, strength_volume_kg, strength_change_kg, strength_change_pct
FROM v_strength_vs_protein ORDER BY full_name, yr_week;

-- 13b. Do higher-protein weeks come with strength gains? (subquery against the overall average protein)
SELECT CASE WHEN avg_daily_protein_g >= (SELECT AVG(avg_daily_protein_g) FROM v_strength_vs_protein)
            THEN 'Higher protein weeks' ELSE 'Lower protein weeks' END AS protein_group,
       COUNT(*) AS weeks, ROUND(AVG(strength_change_pct),1) AS avg_strength_change_pct
FROM v_strength_vs_protein WHERE strength_change_pct IS NOT NULL
GROUP BY protein_group;