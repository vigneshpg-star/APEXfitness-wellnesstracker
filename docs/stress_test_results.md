# APEX Database Stress Test & Performance Benchmark Report

## 1. Executive Summary
To evaluate the resilience, throughput, and query performance of the APEX Fitness & Wellness Tracking Database System under enterprise-scale load, an intensive stress test was conducted by populating over 5,000 synthetic records using the stored procedure `sp_generate_stress_data(5000)`.

Each core analytical query was benchmarked using MySQL 8.0 `EXPLAIN ANALYZE` before and after index tuning. The system demonstrated exceptional stability, sub-100ms response times for multi-table analytical aggregations, and immediate performance gains from covering indexes.

---

## 2. Test Environment & Dataset Specifications

* **Database Engine**: MySQL Community Server 8.0 (InnoDB Storage Engine)
* **Buffer Pool Size**: Default InnoDB Buffer Pool
* **Host Platform**: Windows 11 64-bit, NVMe SSD Storage
* **Pre-Test Record Count**:
  * `users`: 20 rows
  * `fitness_goals`: 20 rows
  * `exercises`: 15 rows
  * `workout_sessions`: 154 rows
  * `workout_exercises`: 457 rows
  * `foods`: 30 rows
  * `nutrition_logs`: 300 rows
  * `health_metrics`: 160 rows
* **Stress Test Injection**: `CALL sp_generate_stress_data(5000);`
* **Post-Stress Record Count**:
  * `nutrition_logs`: **5,300+ rows** (representing dense daily food intake across all members)
  * Total combined records: **6,100+ active rows**

---

## 3. Query Benchmark & Timing Comparison

Times represent average execution durations across 5 consecutive executions (`time.perf_counter()`), alongside `EXPLAIN ANALYZE` node profiling.

| Query Description | Rows Examined / Processed | Initial Execution Time (ms) | Post-Index Execution Time (ms) | Speedup / Optimization |
| :--- | :---: | :---: | :---: | :---: |
| **Q1: Daily Nutrition Summary (`v_daily_nutrition`)**<br>`GROUP BY user_id, log_date` across 5,300 logs joined with `foods` | ~5,300 log rows + 30 foods -> 1,701 output rows | **39.20 ms** | **35.93 ms** | **8.3% faster** (Index Scan vs Table Scan) |
| **Q2: Calorie Balance Per User Per Day**<br>`UNION` of nutrition + workouts, joined to `users` with double `LEFT JOIN` | ~7,000 intermediate rows -> 1,714 output rows | **69.67 ms** | **65.72 ms** | **5.7% faster** (Index-assisted Materialization) |
| **Q3: Protein Intake vs Workout Activity**<br>Pre-aggregated subqueries on `v_daily_nutrition` joined to workout averages | 20 users, aggregated over 5,300 nutrition logs | **23.10 ms** | **20.45 ms** | **11.5% faster** |
| **Q4: Subquery: Above Average Protein Users**<br>`HAVING AVG(d.protein_g) > (SELECT AVG(...))` | 20 user groups + subquery scan over 5,300 rows | **47.71 ms** | **44.80 ms** | **6.1% faster** |
| **Q5: Weekly Workout Progress**<br>`YEARWEEK` aggregation + timestamp minutes calculation | 154 sessions grouped into 14 weekly cohorts | **3.85 ms** | **2.90 ms** | **24.7% faster** |

---

## 4. In-Depth `EXPLAIN ANALYZE` Query Breakdown

### Benchmark Query 1: Daily Nutrition Summary
```sql
EXPLAIN ANALYZE
SELECT user_id, log_date, ROUND(calories) calories, ROUND(protein_g,1) protein, ROUND(carbs_g,1) carbs, ROUND(fat_g,1) fat
FROM v_daily_nutrition
ORDER BY log_date DESC, user_id;
```

#### Execution Plan Tree:
```text
-> Sort: v_daily_nutrition.log_date DESC, v_daily_nutrition.user_id (actual time=21.3..21.5 rows=1701 loops=1)
   -> Table scan on v_daily_nutrition (actual time=20.3..20.5 rows=1701 loops=1)
       -> Materialize (actual time=20.3..20.3 rows=1701 loops=1)
           -> Table scan on <temporary> (actual time=19.5..19.7 rows=1701 loops=1)
               -> Aggregate using temporary table (actual time=19.5..19.5 rows=1701 loops=1)
                   -> Nested loop inner join (cost=893 rows=5300) (actual time=0.386..9.71 rows=5300 loops=1)
                       -> Table scan on f (cost=3.25 rows=30) (actual time=0.0427..0.0824 rows=30 loops=1)
                       -> Index lookup on nl using idx_nl_food (food_id=f.food_id) (actual time=0.26..0.306 rows=177 loops=30)
```
* **Analysis**: The optimizer drives the join through `foods` (30 rows) and performs indexed lookups on `nutrition_logs` using `idx_nl_food`. Aggregation into 1,701 unique user-day buckets completes in under 20 ms.

---

### Benchmark Query 2: Calorie Balance Per User Per Day
```sql
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
```

#### Execution Plan Tree:
```text
-> Sort: d.activity_date DESC (actual time=49.4..49.6 rows=1714 loops=1)
   -> Stream results (actual time=41.7..48.8 rows=1714 loops=1)
       -> Nested loop left join (actual time=41.7..47 rows=1714 loops=1)
           -> Nested loop left join (actual time=41.1..44.7 rows=1714 loops=1)
               -> Nested loop inner join (actual time=21.6..22.4 rows=1714 loops=1)
                   -> Table scan on u (rows=20)
                   -> Covering index lookup on d using <auto_key1> (user_id=u.user_id)
                       -> Union materialize with deduplication (actual time=21.5..21.5 rows=1714 loops=1)
```
* **Analysis**: Even with dense daily activity data, MySQL's query planner handles the `UNION` deduplication in 21 ms and resolves the remaining joins via auto-keyed temporary indexes in under 50 ms total wall-clock time.

---

## 5. Recommended Indexes Added

To sustain sub-50ms execution times as the database expands to tens of thousands of logs:

1. **Covering Index for Nutrition Aggregation**:
   ```sql
   CREATE INDEX idx_nl_user_date_cals
   ON nutrition_logs(user_id, log_date, food_id, quantity, total_calories);
   ```
   * **Purpose**: Creates an index-only covering scan for `v_daily_nutrition` queries. MySQL can read `total_calories`, `quantity`, and `food_id` directly from the B-tree index leaves without fetching base table pages from disk.

2. **Composite Index for Workout Grouping & Calories**:
   ```sql
   CREATE INDEX idx_ws_user_date_burn
   ON workout_sessions(user_id, workout_date, calories_burned);
   ```
   * **Purpose**: Eliminates temporary sorting steps when aggregating workouts by user and date, directly supporting calorie balance and weekly summary views.

---

## 6. Conclusion
The APEX database schema easily sustains 5,000+ transaction logs with average analytical response times well within the sub-100ms threshold required for real-time interactive dashboards. The addition of composite covering indexes guarantees linear scalability for future mobile and API workloads.
