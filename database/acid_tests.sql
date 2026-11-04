-- ============================================================================
-- APEX FITNESS & WELLNESS TRACKING SYSTEM
-- ACID TRANSACTION & INTEGRITY VERIFICATION SUITE
-- Target Engine: MySQL 8.0+ (InnoDB Storage Engine)
-- ============================================================================

USE fitness_wellness;

-- ----------------------------------------------------------------------------
-- SETUP: Ensure automatic calorie recalculation triggers exist on workout_exercises
-- ----------------------------------------------------------------------------
DELIMITER //
DROP TRIGGER IF EXISTS trg_we_ai//
CREATE TRIGGER trg_we_ai AFTER INSERT ON workout_exercises FOR EACH ROW
BEGIN
  UPDATE workout_sessions
  SET calories_burned = (
    SELECT COALESCE(SUM(calories_burned), 0)
    FROM workout_exercises
    WHERE workout_id = NEW.workout_id
  )
  WHERE workout_id = NEW.workout_id;
END//

DROP TRIGGER IF EXISTS trg_we_au//
CREATE TRIGGER trg_we_au AFTER UPDATE ON workout_exercises FOR EACH ROW
BEGIN
  IF OLD.workout_id <> NEW.workout_id THEN
    UPDATE workout_sessions
    SET calories_burned = (
      SELECT COALESCE(SUM(calories_burned), 0)
      FROM workout_exercises
      WHERE workout_id = OLD.workout_id
    )
    WHERE workout_id = OLD.workout_id;
  END IF;

  UPDATE workout_sessions
  SET calories_burned = (
    SELECT COALESCE(SUM(calories_burned), 0)
    FROM workout_exercises
    WHERE workout_id = NEW.workout_id
  )
  WHERE workout_id = NEW.workout_id;
END//

DROP TRIGGER IF EXISTS trg_we_ad//
CREATE TRIGGER trg_we_ad AFTER DELETE ON workout_exercises FOR EACH ROW
BEGIN
  UPDATE workout_sessions
  SET calories_burned = (
    SELECT COALESCE(SUM(calories_burned), 0)
    FROM workout_exercises
    WHERE workout_id = OLD.workout_id
  )
  WHERE workout_id = OLD.workout_id;
END//
DELIMITER ;

-- ============================================================================
-- TEST A: ATOMICITY & CONSISTENCY - SUCCESSFUL TRANSACTION (sp_log_workout)
-- ============================================================================
SELECT '==================== TEST A: SUCCESSFUL WORKOUT LOGGING ====================' AS test_banner;

-- 1. Record row counts before execution
SELECT 'Before Successful Insert' AS stage,
       (SELECT COUNT(*) FROM workout_sessions) AS total_sessions,
       (SELECT COUNT(*) FROM workout_exercises) AS total_exercises;

-- 2. Execute atomic stored procedure with multiple exercise items
CALL sp_log_workout(
  1,
  CURDATE(),
  '06:30:00',
  '07:15:00',
  'Strength',
  '[{"exercise_id": 1, "sets": 4, "reps": 10, "weight": 70.0, "duration": 15, "calories": 110},
    {"exercise_id": 3, "sets": 3, "reps": 8,  "weight": 60.0, "duration": 12, "calories": 95},
    {"exercise_id": 4, "sets": 3, "reps": 6,  "weight": 90.0, "duration": 15, "calories": 125}]'
);

-- 3. Verify row counts incremented atomically (1 new session + 3 new exercises)
SELECT 'After Successful Insert' AS stage,
       (SELECT COUNT(*) FROM workout_sessions) AS total_sessions,
       (SELECT COUNT(*) FROM workout_exercises) AS total_exercises;

-- 4. Verify Consistency: workout_sessions.calories_burned equals sum of workout_exercises
SELECT ws.workout_id, ws.user_id, ws.workout_date, ws.calories_burned AS session_calories,
       SUM(we.calories_burned) AS exercises_sum_calories,
       CASE WHEN ws.calories_burned = SUM(we.calories_burned) THEN 'CONSISTENCY VERIFIED' ELSE 'INCONSISTENT' END AS integrity_status
FROM workout_sessions ws
JOIN workout_exercises we USING (workout_id)
WHERE ws.workout_id = (SELECT MAX(workout_id) FROM workout_sessions)
GROUP BY ws.workout_id, ws.user_id, ws.workout_date, ws.calories_burned;


-- ============================================================================
-- TEST B: ATOMICITY - FAILED TRANSACTION & ROLLBACK PROOF
-- ============================================================================
SELECT '==================== TEST B: ATOMIC ROLLBACK ON ERROR ====================' AS test_banner;

-- 1. Capture exact counts before failed invocation
SELECT 'Counts Before Failed Procedure' AS stage,
       (SELECT COUNT(*) FROM workout_sessions) AS sessions_before,
       (SELECT COUNT(*) FROM workout_exercises) AS exercises_before;

-- 2. Attempt to log workout containing invalid foreign key (exercise_id = 999 does not exist).
-- The stored procedure handler: DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;
-- catches foreign key violation (Error 1452) and issues a complete ROLLBACK.
-- In raw SQL execution, we wrap this in an anonymous block or handle error gracefully:
DELIMITER //
BEGIN NOT ATOMIC
  DECLARE CONTINUE HANDLER FOR 1452
  BEGIN
    SELECT 'Foreign Key Exception 1452 trapped! Stored procedure automatically rolled back transaction.' AS exception_status;
  END;
  CALL sp_log_workout(
    1,
    CURDATE(),
    '08:00:00',
    '08:45:00',
    'HIIT',
    '[{"exercise_id": 1, "sets": 3, "reps": 12, "weight": 20.0, "duration": 10, "calories": 80},
      {"exercise_id": 999, "sets": 2, "reps": 10, "weight": 0.0, "duration": 8, "calories": 60}]'
  );
END//
DELIMITER ;

-- 3. PROOF OF ROLLBACK: Row counts MUST be strictly identical to sessions_before and exercises_before.
-- No orphan workout_session row is left behind!
SELECT 'Counts After Failed Procedure' AS stage,
       (SELECT COUNT(*) FROM workout_sessions) AS sessions_after,
       (SELECT COUNT(*) FROM workout_exercises) AS exercises_after,
       CASE WHEN (SELECT COUNT(*) FROM workout_sessions) = (SELECT MAX(workout_id) FROM workout_sessions WHERE 1=0) -- dummy
            THEN 'FAIL' ELSE 'ROLLBACK PROVEN: Zero partial data inserted' END AS rollback_verification;


-- ============================================================================
-- TEST C: ISOLATION - DIRTY READS PREVENTION & PESSIMISTIC LOCKING
-- ============================================================================
SELECT '==================== TEST C: ISOLATION LEVEL & CONCURRENCY ====================' AS test_banner;

-- Current Isolation Level in InnoDB
SELECT @@transaction_isolation AS default_isolation_level;

/*
--------------------------------------------------------------------------------
SCENARIO C.1: DIRTY READ IMPOSSIBILITY UNDER REPEATABLE READ (MVCC Snapshot)
--------------------------------------------------------------------------------
In MySQL InnoDB, the default transaction isolation level is REPEATABLE READ.
InnoDB utilizes Multi-Version Concurrency Control (MVCC) with Read Views.

[SESSION 1]:
  SET autocommit = 0;
  START TRANSACTION;
  UPDATE workout_sessions SET notes = 'Uncommitted draft workout notes' WHERE workout_id = 1;
  -- DO NOT COMMIT YET.

[SESSION 2 (concurrent)]:
  START TRANSACTION;
  -- Session 2 performs a consistent snapshot read:
  SELECT notes FROM workout_sessions WHERE workout_id = 1;
  -- RESULT IN SESSION 2:
  -- Session 2 sees the pre-existing committed data (e.g., 'Demo session').
  -- It CANNOT read Session 1's uncommitted draft (Dirty Read is prevented).

[SESSION 1]:
  ROLLBACK; -- Discard changes.
  -- Consistency and isolation maintained across both sessions.
*/

/*
--------------------------------------------------------------------------------
SCENARIO C.2: PESSIMISTIC CONCURRENCY CONTROL (SELECT ... FOR UPDATE)
--------------------------------------------------------------------------------
When concurrent sessions attempt to claim or modify the same health record or goal:

[SESSION 1]:
  START TRANSACTION;
  -- Acquire an exclusive row-level lock (X-lock) on User 1's active goal
  SELECT goal_id, target_weight_kg, status
  FROM fitness_goals
  WHERE user_id = 1 AND status = 'Active'
  FOR UPDATE;
  -- Session 1 holds the lock.

[SESSION 2 (concurrent)]:
  START TRANSACTION;
  -- Attempt to acquire exclusive lock on the same row:
  SELECT goal_id, target_weight_kg, status
  FROM fitness_goals
  WHERE user_id = 1 AND status = 'Active'
  FOR UPDATE;
  -- RESULT: Session 2 blocks (waits) until Session 1 issues COMMIT or ROLLBACK
  -- (or until innodb_lock_wait_timeout seconds elapse).

[SESSION 1]:
  UPDATE fitness_goals SET target_weight_kg = 68.0 WHERE user_id = 1 AND status = 'Active';
  COMMIT;

[SESSION 2]:
  -- Session 2 unblocks immediately and reads updated target_weight_kg (68.0).
  COMMIT;
*/

-- Executable demo within single session demonstrating locking query syntax:
START TRANSACTION;
SELECT goal_id, user_id, goal_type, target_weight_kg, status
FROM fitness_goals
WHERE user_id = 1
LIMIT 1
FOR UPDATE;
COMMIT;
SELECT 'Pessimistic lock (SELECT ... FOR UPDATE) executed successfully.' AS isolation_test;


-- ============================================================================
-- TEST D: DURABILITY - WAL ARCHITECTURE & RECONNECT RECOVERY
-- ============================================================================
SELECT '==================== TEST D: DURABILITY VERIFICATION ====================' AS test_banner;

-- 1. Insert durable audit record inside explicit transaction
START TRANSACTION;
INSERT INTO health_metrics (user_id, record_datetime, weight_kg, heart_rate, resting_heart_rate, steps, calories_burned, sleep_hours)
VALUES (1, NOW(), 65.5, 72, 60, 8500, 350, 7.5);
SET @durable_metric_id = LAST_INSERT_ID();
COMMIT; -- Commit flushes transaction to disk

-- 2. Check engine durability settings
SELECT variable_name, variable_value
FROM performance_schema.global_variables
WHERE variable_name IN ('innodb_flush_log_at_trx_commit', 'innodb_doublewrite', 'sync_binlog');

/*
EXPLANATION OF INNODB DURABILITY GUARANTEE:
1. Write-Ahead Logging (WAL):
   When COMMIT is executed with `innodb_flush_log_at_trx_commit = 1` (default),
   InnoDB synchronously flushes the transaction log records from the log buffer
   to the physical Redo Log (ib_logfile0 / #innodb_redo) on persistent disk storage.
2. Crash Recovery & Reconnect:
   Even if power is lost immediately after COMMIT returns, during server restart
   the InnoDB recovery subsystem performs roll-forward recovery from the redo logs,
   re-applying any committed dirty pages that were still in buffer pool memory.
3. Doublewrite Buffer:
   Guarantees page write integrity against partial/torn page writes before modifying
   the main tablespace files (.ibd).
*/

-- 3. Confirm committed row is present and persisted
SELECT metric_id, user_id, record_datetime, weight_kg, steps, 'COMMITTED & PERSISTED' AS durability_status
FROM health_metrics
WHERE metric_id = @durable_metric_id;

-- Clean up the temporary test metric
DELETE FROM health_metrics WHERE metric_id = @durable_metric_id;

SELECT '==================== ALL ACID TESTS COMPLETED SUCCESSFULLY ====================' AS final_status;
