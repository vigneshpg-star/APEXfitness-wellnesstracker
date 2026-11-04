-- Fitness & Wellness Tracking Database System (MySQL 8.0+)
DROP DATABASE IF EXISTS fitness_wellness;
CREATE DATABASE fitness_wellness CHARACTER SET utf8mb4;
USE fitness_wellness;

-- ===================== TABLES (3NF) =====================
CREATE TABLE users (
  user_id INT AUTO_INCREMENT PRIMARY KEY,
  full_name VARCHAR(100) NOT NULL,
  email VARCHAR(120) NOT NULL UNIQUE,
  date_of_birth DATE NOT NULL,
  gender ENUM('Male','Female','Other') NOT NULL,
  height_cm DECIMAL(5,1) NOT NULL,
  registration_date DATE NOT NULL DEFAULT (CURRENT_DATE),
  CONSTRAINT chk_user_height CHECK (height_cm > 0 AND height_cm < 280)
) ENGINE=InnoDB;

CREATE TABLE fitness_goals (
  goal_id INT AUTO_INCREMENT PRIMARY KEY,
  user_id INT NOT NULL,
  goal_type ENUM('Weight Loss','Weight Gain','Muscle Building','General Fitness','Endurance') NOT NULL,
  target_weight_kg DECIMAL(5,2),
  target_calories INT,
  target_steps INT,
  target_date DATE,
  status ENUM('Active','Achieved','Abandoned') NOT NULL DEFAULT 'Active',
  CONSTRAINT fk_goal_user FOREIGN KEY (user_id) REFERENCES users(user_id) ON DELETE CASCADE ON UPDATE CASCADE,
  CONSTRAINT chk_goal CHECK (COALESCE(target_weight_kg,1)>0 AND COALESCE(target_calories,1)>0 AND COALESCE(target_steps,0)>=0),
  INDEX idx_goal_user (user_id, status)
) ENGINE=InnoDB;

CREATE TABLE exercises (
  exercise_id INT AUTO_INCREMENT PRIMARY KEY,
  exercise_name VARCHAR(80) NOT NULL UNIQUE,
  category ENUM('Strength','Cardio','Flexibility','HIIT') NOT NULL,
  muscle_group VARCHAR(40) NOT NULL,
  description VARCHAR(255)
) ENGINE=InnoDB;

CREATE TABLE workout_sessions (
  workout_id INT AUTO_INCREMENT PRIMARY KEY,
  user_id INT NOT NULL,
  workout_date DATE NOT NULL,
  start_time TIME NOT NULL,
  end_time TIME NOT NULL,
  workout_type VARCHAR(40) NOT NULL,
  calories_burned INT NOT NULL DEFAULT 0,
  notes VARCHAR(255),
  CONSTRAINT fk_ws_user FOREIGN KEY (user_id) REFERENCES users(user_id) ON DELETE CASCADE ON UPDATE CASCADE,
  CONSTRAINT chk_ws CHECK (end_time > start_time AND calories_burned >= 0),
  INDEX idx_ws_user_date (user_id, workout_date), INDEX idx_ws_date (workout_date)
) ENGINE=InnoDB;

-- Junction table: workouts <-> exercises (many-to-many). Exercise name lives ONLY in exercises.
CREATE TABLE workout_exercises (
  workout_exercise_id INT AUTO_INCREMENT PRIMARY KEY,
  workout_id INT NOT NULL,
  exercise_id INT NOT NULL,
  sets INT, repetitions INT,
  weight_used_kg DECIMAL(6,2),
  duration_minutes INT,
  calories_burned INT NOT NULL DEFAULT 0,
  CONSTRAINT fk_we_workout FOREIGN KEY (workout_id) REFERENCES workout_sessions(workout_id) ON DELETE CASCADE ON UPDATE CASCADE,
  CONSTRAINT fk_we_exercise FOREIGN KEY (exercise_id) REFERENCES exercises(exercise_id) ON DELETE RESTRICT ON UPDATE CASCADE,
  CONSTRAINT chk_we CHECK (COALESCE(sets,0)>=0 AND COALESCE(repetitions,0)>=0 AND COALESCE(weight_used_kg,0)>=0
                           AND COALESCE(duration_minutes,0)>=0 AND calories_burned>=0),
  INDEX idx_we_workout (workout_id), INDEX idx_we_exercise (exercise_id)
) ENGINE=InnoDB;

CREATE TABLE foods (
  food_id INT AUTO_INCREMENT PRIMARY KEY,
  food_name VARCHAR(80) NOT NULL UNIQUE,
  category VARCHAR(40) NOT NULL,
  serving_size VARCHAR(40) NOT NULL,
  calories DECIMAL(7,2) NOT NULL, protein_g DECIMAL(6,2) NOT NULL,
  carbs_g DECIMAL(6,2) NOT NULL, fat_g DECIMAL(6,2) NOT NULL, fiber_g DECIMAL(6,2) NOT NULL DEFAULT 0,
  CONSTRAINT chk_food CHECK (calories>=0 AND protein_g>=0 AND carbs_g>=0 AND fat_g>=0 AND fiber_g>=0)
) ENGINE=InnoDB;

CREATE TABLE nutrition_logs (
  nutrition_log_id INT AUTO_INCREMENT PRIMARY KEY,
  user_id INT NOT NULL, food_id INT NOT NULL,
  log_date DATE NOT NULL,
  meal_type ENUM('Breakfast','Lunch','Dinner','Snack') NOT NULL,
  quantity DECIMAL(5,2) NOT NULL,           -- number of servings
  total_calories DECIMAL(8,2) NOT NULL,     -- snapshot = quantity * foods.calories (set by trigger)
  CONSTRAINT fk_nl_user FOREIGN KEY (user_id) REFERENCES users(user_id) ON DELETE CASCADE ON UPDATE CASCADE,
  CONSTRAINT fk_nl_food FOREIGN KEY (food_id) REFERENCES foods(food_id) ON DELETE RESTRICT ON UPDATE CASCADE,
  CONSTRAINT chk_nl CHECK (quantity > 0 AND total_calories >= 0),
  INDEX idx_nl_user_date (user_id, log_date), INDEX idx_nl_date (log_date), INDEX idx_nl_food (food_id)
) ENGINE=InnoDB;

-- Height is NOT stored here: BMI is derived via view from users.height_cm (no duplicate data).
CREATE TABLE health_metrics (
  metric_id INT AUTO_INCREMENT PRIMARY KEY,
  user_id INT NOT NULL,
  record_datetime DATETIME NOT NULL,
  weight_kg DECIMAL(5,2) NOT NULL,
  heart_rate INT, resting_heart_rate INT,
  steps INT NOT NULL DEFAULT 0,
  calories_burned INT NOT NULL DEFAULT 0,
  sleep_hours DECIMAL(4,2) NOT NULL DEFAULT 0,
  CONSTRAINT fk_hm_user FOREIGN KEY (user_id) REFERENCES users(user_id) ON DELETE CASCADE ON UPDATE CASCADE,
  CONSTRAINT chk_hm CHECK (weight_kg>0 AND weight_kg<500 AND COALESCE(heart_rate,40) BETWEEN 25 AND 250
     AND COALESCE(resting_heart_rate,40) BETWEEN 25 AND 150 AND steps>=0 AND calories_burned>=0 AND sleep_hours BETWEEN 0 AND 24),
  INDEX idx_hm_user_dt (user_id, record_datetime), INDEX idx_hm_dt (record_datetime)
) ENGINE=InnoDB;

-- ===================== TRIGGERS / VIEWS =====================
DELIMITER //
CREATE TRIGGER trg_nl_total BEFORE INSERT ON nutrition_logs FOR EACH ROW
BEGIN SET NEW.total_calories = NEW.quantity * (SELECT calories FROM foods WHERE food_id = NEW.food_id); END//
CREATE TRIGGER trg_nl_total_upd BEFORE UPDATE ON nutrition_logs FOR EACH ROW
BEGIN SET NEW.total_calories = NEW.quantity * (SELECT calories FROM foods WHERE food_id = NEW.food_id); END//

-- Recalculate workout_sessions.calories_burned automatically when workout_exercises change
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

CREATE VIEW v_health_metrics_bmi AS
SELECT hm.*, u.full_name, u.height_cm,
       ROUND(hm.weight_kg / POW(u.height_cm/100, 2), 2) AS bmi
FROM health_metrics hm JOIN users u USING (user_id);

CREATE VIEW v_workout_details AS
SELECT ws.workout_id, ws.user_id, u.full_name, ws.workout_date, ws.workout_type,
       e.exercise_name, we.sets, we.repetitions, we.weight_used_kg, we.duration_minutes, we.calories_burned
FROM workout_sessions ws JOIN users u USING (user_id)
JOIN workout_exercises we USING (workout_id) JOIN exercises e USING (exercise_id);

CREATE VIEW v_daily_nutrition AS
SELECT nl.user_id, nl.log_date, SUM(nl.total_calories) calories, SUM(nl.quantity*f.protein_g) protein_g,
       SUM(nl.quantity*f.carbs_g) carbs_g, SUM(nl.quantity*f.fat_g) fat_g
FROM nutrition_logs nl JOIN foods f USING (food_id) GROUP BY nl.user_id, nl.log_date;

-- Heart rate zones: % of estimated max HR (220 - age at the reading)
CREATE VIEW v_heart_rate_zones AS
SELECT t.*,
  CASE WHEN pct_of_max < 50 THEN 'Z0 Rest (<50%)'
       WHEN pct_of_max < 60 THEN 'Z1 Very Light (50-60%)'
       WHEN pct_of_max < 70 THEN 'Z2 Fat Burn (60-70%)'
       WHEN pct_of_max < 80 THEN 'Z3 Aerobic (70-80%)'
       WHEN pct_of_max < 90 THEN 'Z4 Threshold (80-90%)'
       ELSE 'Z5 Maximum (90%+)' END AS hr_zone
FROM (SELECT hm.metric_id, hm.user_id, u.full_name, hm.record_datetime, hm.heart_rate,
             220 - TIMESTAMPDIFF(YEAR, u.date_of_birth, hm.record_datetime) AS max_hr,
             ROUND(hm.heart_rate * 100 / (220 - TIMESTAMPDIFF(YEAR, u.date_of_birth, hm.record_datetime)), 1) AS pct_of_max
      FROM health_metrics hm JOIN users u USING (user_id)
      WHERE hm.heart_rate IS NOT NULL) t;

-- Macronutrient ratio: share of calories from protein (4 kcal/g), carbs (4 kcal/g), fat (9 kcal/g)
CREATE VIEW v_macro_ratios AS
SELECT user_id, log_date, ROUND(calories) AS calories,
       ROUND(protein_g,1) AS protein_g, ROUND(carbs_g,1) AS carbs_g, ROUND(fat_g,1) AS fat_g,
       ROUND(protein_g*4*100 / NULLIF(protein_g*4 + carbs_g*4 + fat_g*9, 0), 1) AS protein_pct,
       ROUND(carbs_g*4*100   / NULLIF(protein_g*4 + carbs_g*4 + fat_g*9, 0), 1) AS carbs_pct,
       ROUND(fat_g*9*100     / NULLIF(protein_g*4 + carbs_g*4 + fat_g*9, 0), 1) AS fat_pct
FROM v_daily_nutrition;

-- Strength gain vs protein intake (weekly): lifting volume = sets x reps x kg on Strength exercises
CREATE VIEW v_strength_vs_protein AS
WITH wk_protein AS (
  SELECT user_id, YEARWEEK(log_date,1) AS yr_week, AVG(protein_g) AS avg_protein
  FROM v_daily_nutrition GROUP BY user_id, YEARWEEK(log_date,1)),
wk_strength AS (
  SELECT ws.user_id, YEARWEEK(ws.workout_date,1) AS yr_week,
         SUM(we.sets * we.repetitions * we.weight_used_kg) AS volume_kg
  FROM workout_sessions ws
  JOIN workout_exercises we USING (workout_id)
  JOIN exercises e USING (exercise_id)
  WHERE e.category = 'Strength'
  GROUP BY ws.user_id, YEARWEEK(ws.workout_date,1))
SELECT p.user_id, u.full_name, p.yr_week,
       ROUND(p.avg_protein,1) AS avg_daily_protein_g,
       ROUND(s.volume_kg,0) AS strength_volume_kg,
       ROUND(s.volume_kg - LAG(s.volume_kg) OVER w, 0) AS strength_change_kg,
       ROUND((s.volume_kg - LAG(s.volume_kg) OVER w) * 100 / NULLIF(LAG(s.volume_kg) OVER w, 0), 1) AS strength_change_pct
FROM wk_protein p
JOIN wk_strength s ON s.user_id = p.user_id AND s.yr_week = p.yr_week
JOIN users u ON u.user_id = p.user_id
WINDOW w AS (PARTITION BY p.user_id ORDER BY p.yr_week);

-- ===================== SAMPLE DATA =====================
INSERT INTO exercises (exercise_name, category, muscle_group, description) VALUES
('Squats','Strength','Legs','Barbell back squat'),('Push-ups','Strength','Chest','Bodyweight press'),
('Bench Press','Strength','Chest','Flat barbell press'),('Deadlift','Strength','Back','Conventional deadlift'),
('Running','Cardio','Full Body','Steady-state run'),('Cycling','Cardio','Legs','Stationary or road bike'),
('Pull-ups','Strength','Back','Bodyweight pull'),('Lunges','Strength','Legs','Walking lunges'),
('Plank','Strength','Core','Isometric hold'),('Burpees','HIIT','Full Body','Explosive full-body move'),
('Rowing','Cardio','Back','Rowing machine'),('Yoga Flow','Flexibility','Full Body','Vinyasa sequence'),
('Shoulder Press','Strength','Shoulders','Overhead dumbbell press'),('Jump Rope','HIIT','Legs','Skipping'),
('Swimming','Cardio','Full Body','Freestyle laps');

INSERT INTO foods (food_name, category, serving_size, calories, protein_g, carbs_g, fat_g, fiber_g) VALUES
('Oatmeal','Grains','1 cup',150,5,27,3,4),('Boiled Egg','Protein','1 large',78,6.3,0.6,5.3,0),
('Grilled Chicken Breast','Protein','100 g',165,31,0,3.6,0),('Brown Rice','Grains','1 cup',216,5,45,1.8,3.5),
('Banana','Fruit','1 medium',105,1.3,27,0.4,3.1),('Greek Yogurt','Dairy','170 g',100,17,6,0.7,0),
('Almonds','Nuts','28 g',164,6,6,14,3.5),('Salmon','Protein','100 g',208,20,0,13,0),
('Broccoli','Vegetable','1 cup',55,3.7,11,0.6,5.1),('Whole Wheat Bread','Grains','2 slices',160,8,28,2.5,4),
('Apple','Fruit','1 medium',95,0.5,25,0.3,4.4),('Paneer','Dairy','100 g',265,18,1.2,20,0),
('Lentil Dal','Legumes','1 cup',230,18,40,0.8,15.6),('Chapati','Grains','1 piece',104,3,18,2.5,2.7),
('Whey Protein Shake','Supplement','1 scoop',120,24,3,1.5,0),('Sweet Potato','Vegetable','1 medium',112,2,26,0.1,3.9),
('Tofu','Protein','100 g',144,17,3,9,2.3),('Avocado','Fruit','1/2 fruit',160,2,9,15,6.7),
('Peanut Butter','Spread','2 tbsp',188,8,6,16,1.9),('Milk (Skimmed)','Dairy','1 cup',83,8,12,0.2,0),
('Quinoa','Grains','1 cup',222,8,39,3.6,5.2),('Tuna (Canned)','Protein','100 g',116,26,0,1,0),
('Idli','Grains','2 pieces',116,4,24,0.4,1.2),('Dosa','Grains','1 piece',168,4,29,3.7,1.1),
('Chickpea Curry','Legumes','1 cup',269,14.5,45,4.2,12.5),('Orange','Fruit','1 medium',62,1.2,15.4,0.2,3.1),
('Cottage Cheese','Dairy','100 g',98,11,3.4,4.3,0),('Mixed Salad','Vegetable','1 bowl',45,2,8,0.5,3),
('Dark Chocolate','Snack','30 g',170,2,13,12,3),('Protein Bar','Snack','1 bar',200,20,22,7,3);

INSERT INTO users (full_name,email,date_of_birth,gender,height_cm,registration_date) VALUES
('Aarav Nair','aarav.nair@example.com','1998-04-12','Male',176.0,'2026-01-05'),
('Meera Pillai','meera.pillai@example.com','1995-09-23','Female',162.5,'2026-01-07'),
('Rohan Menon','rohan.menon@example.com','1990-01-30','Male',181.0,'2026-01-09'),
('Anjali Varma','anjali.varma@example.com','2000-06-14','Female',158.0,'2026-01-12'),
('Vikram Iyer','vikram.iyer@example.com','1987-11-02','Male',172.0,'2026-01-15'),
('Sneha Kurian','sneha.kurian@example.com','1993-03-18','Female',165.0,'2026-01-18'),
('Arjun Das','arjun.das@example.com','1999-08-08','Male',179.5,'2026-01-20'),
('Divya Thomas','divya.thomas@example.com','1996-12-25','Female',160.0,'2026-01-22'),
('Karthik Raj','karthik.raj@example.com','1985-05-05','Male',170.0,'2026-01-25'),
('Neha Joseph','neha.joseph@example.com','2001-02-11','Female',167.0,'2026-01-28'),
('Sanjay Nambiar','sanjay.nambiar@example.com','1992-07-19','Male',183.0,'2026-02-01'),
('Lakshmi Krishnan','lakshmi.k@example.com','1989-10-10','Female',155.5,'2026-02-03'),
('Rahul Sharma','rahul.sharma@example.com','1997-04-27','Male',174.0,'2026-02-05'),
('Priya Singh','priya.singh@example.com','1994-01-16','Female',163.0,'2026-02-08'),
('Aditya Verma','aditya.verma@example.com','1991-09-09','Male',177.0,'2026-02-10'),
('Fatima Rahman','fatima.rahman@example.com','1998-11-21','Female',161.0,'2026-02-12'),
('Manoj George','manoj.george@example.com','1983-03-03','Male',169.0,'2026-02-15'),
('Isha Patel','isha.patel@example.com','2002-05-30','Female',166.0,'2026-02-18'),
('Gokul Anand','gokul.anand@example.com','1996-08-14','Male',185.0,'2026-02-20'),
('Tara Mathew','tara.mathew@example.com','1990-12-01','Female',159.0,'2026-02-22');

INSERT INTO fitness_goals (user_id,goal_type,target_weight_kg,target_calories,target_steps,target_date,status)
SELECT user_id,
  ELT(1+MOD(user_id,5),'Weight Loss','Muscle Building','General Fitness','Endurance','Weight Gain'),
  60+MOD(user_id*7,30), 1800+MOD(user_id*90,900), 8000+MOD(user_id*500,4000), '2026-12-31', 'Active'
FROM users;

-- Number helper (1..1000) used to generate deterministic, realistic dummy data
CREATE TABLE _seq AS
WITH RECURSIVE s(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM s WHERE n < 1000) SELECT n FROM s;

-- 150 workout sessions over the last 90 days
INSERT INTO workout_sessions (user_id,workout_date,start_time,end_time,workout_type,calories_burned,notes)
SELECT 1+MOD(n*7,20), DATE_SUB(CURDATE(), INTERVAL MOD(n*5,90) DAY),
       MAKETIME(6+MOD(n,14),0,0), MAKETIME(6+MOD(n,14),30+MOD(n,30),0),
       ELT(1+MOD(n,4),'Strength','Cardio','HIIT','Mixed'), 0, 'Demo session'
FROM _seq WHERE n <= 150;

-- 3 exercises per session (450 rows)
INSERT INTO workout_exercises (workout_id,exercise_id,sets,repetitions,weight_used_kg,duration_minutes,calories_burned)
SELECT ws.workout_id, 1+MOD(ws.workout_id*k.k*3,15), 3+MOD(k.k,3), 8+MOD(ws.workout_id,5),
       10+MOD(ws.workout_id*k.k,60), 8+MOD(ws.workout_id+k.k,12), 40+MOD(ws.workout_id*k.k,80)
FROM workout_sessions ws JOIN (SELECT 1 k UNION SELECT 2 UNION SELECT 3) k;

UPDATE workout_sessions ws SET calories_burned =
  (SELECT SUM(calories_burned) FROM workout_exercises WHERE workout_id = ws.workout_id);

-- 300 nutrition logs (trigger fills total_calories)
INSERT INTO nutrition_logs (user_id,food_id,log_date,meal_type,quantity,total_calories)
SELECT 1+MOD(n*3,20), 1+MOD(n*7,30), DATE_SUB(CURDATE(), INTERVAL MOD(n,45) DAY),
       ELT(1+MOD(n,4),'Breakfast','Lunch','Dinner','Snack'), 1+MOD(n,3)*0.5, 0
FROM _seq WHERE n <= 300;

-- 160 health metrics with gentle weight drift
INSERT INTO health_metrics (user_id,record_datetime,weight_kg,heart_rate,resting_heart_rate,steps,calories_burned,sleep_hours)
SELECT 1+MOD(n,20), TIMESTAMP(DATE_SUB(CURDATE(), INTERVAL FLOOR(n/20)*7 DAY),'07:30:00'),
       62+MOD(n*3,28)-FLOOR(n/20)*0.2, 70+MOD(n*5,40), 55+MOD(n,15),
       4000+MOD(n*397,9000), 1800+MOD(n*53,900), 5+MOD(n,40)/10
FROM _seq WHERE n <= 160;

DROP TABLE _seq;

-- ===================== STORED PROCEDURES =====================
DELIMITER //
-- Stress test: generate N random nutrition logs in one transaction
CREATE PROCEDURE sp_generate_stress_data(IN n INT)
BEGIN
  DECLARE i INT DEFAULT 0;
  START TRANSACTION;
  WHILE i < n DO
    INSERT INTO nutrition_logs (user_id,food_id,log_date,meal_type,quantity,total_calories)
    VALUES (1+FLOOR(RAND()*20), 1+FLOOR(RAND()*30), DATE_SUB(CURDATE(), INTERVAL FLOOR(RAND()*90) DAY),
            ELT(1+FLOOR(RAND()*4),'Breakfast','Lunch','Dinner','Snack'), 1+FLOOR(RAND()*4)*0.5, 0);
    SET i = i + 1;
  END WHILE;
  COMMIT;
END//

-- ACID demo: create workout + exercises + calorie total atomically.
-- p_exercises JSON: [{"exercise_id":1,"sets":3,"reps":8,"weight":60,"duration":10,"calories":90}]
CREATE PROCEDURE sp_log_workout(IN p_user INT, IN p_date DATE, IN p_start TIME, IN p_end TIME,
                                IN p_type VARCHAR(40), IN p_exercises JSON)
BEGIN
  DECLARE v_wid INT; DECLARE v_total INT;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;   -- Atomicity
  START TRANSACTION;
    INSERT INTO workout_sessions (user_id,workout_date,start_time,end_time,workout_type)
    VALUES (p_user,p_date,p_start,p_end,p_type);
    SET v_wid = LAST_INSERT_ID();
    INSERT INTO workout_exercises (workout_id,exercise_id,sets,repetitions,weight_used_kg,duration_minutes,calories_burned)
    SELECT v_wid, j.exercise_id, j.sets, j.reps, j.weight, j.duration, j.cals
    FROM JSON_TABLE(p_exercises,'$[*]' COLUMNS (exercise_id INT PATH '$.exercise_id', sets INT PATH '$.sets',
         reps INT PATH '$.reps', weight DECIMAL(6,2) PATH '$.weight', duration INT PATH '$.duration',
         cals INT PATH '$.calories')) j;
    SELECT COALESCE(SUM(calories_burned),0) INTO v_total FROM workout_exercises WHERE workout_id = v_wid;
    UPDATE workout_sessions SET calories_burned = v_total WHERE workout_id = v_wid;   -- Consistency
  COMMIT;                                                                              -- Durability
  SELECT v_wid AS workout_id, v_total AS calories_burned;
END//
DELIMITER ;

-- Valid call:
CALL sp_log_workout(1,'2026-11-02','07:00:00','07:45:00','Strength',
  '[{"exercise_id":1,"sets":4,"reps":8,"weight":80,"duration":15,"calories":120},
    {"exercise_id":3,"sets":4,"reps":8,"weight":60,"duration":15,"calories":110}]');
-- Failing call (bad exercise_id -> FK error -> everything rolls back, no orphan session):
-- CALL sp_log_workout(1,'2026-11-02','08:00:00','08:30:00','Test','[{"exercise_id":999,"sets":1,"reps":1,"weight":0,"duration":5,"calories":10}]');
-- Stress test:
-- CALL sp_generate_stress_data(5000);