# APEX Fitness & Wellness Tracking System - Database Design Document (DDD)

## 1. System Overview & Scope
The **APEX Fitness & Wellness Tracking System** is an enterprise-grade relational database and web platform engineered to track, analyze, and visualize multi-dimensional personal health data. It supports concurrent multi-user tracking across four core operational pillars:
* **User Identity & Target Goals**: Demographics, anthropometrics, and progressive milestones.
* **Workout & Activity Regimens**: Session logging, multi-exercise decomposition, resistance training volume, and cardiovascular metrics.
* **Nutritional Profiling**: Food cataloging, macro splits (protein, carbohydrates, fats, dietary fiber), and meal diaries.
* **Continuous Biometrics**: Wearable/sensor metrics including continuous weight tracking, resting/active heart rate, step count, and sleep architecture.

---

## 2. Database Architecture & Storage Engine Specifications
* **Database Management System**: MySQL Community Server 8.0+
* **Default Storage Engine**: `InnoDB` (ACID transactions, Row-Level Locking, Crash Recovery)
* **Default Character Set**: `utf8mb4` (Full Unicode support including multilingual inputs and symbols)
* **Collation**: `utf8mb4_0900_ai_ci`
* **Transaction Isolation Level**: `REPEATABLE READ` (Multi-Version Concurrency Control)

---

## 3. Relational Schema & Table Specifications

### 3.1 Table: `users`
Stores unique member profiles and invariant anthropometric baselines.
* **Columns**:
  * `user_id` `INT AUTO_INCREMENT PRIMARY KEY`
  * `full_name` `VARCHAR(100) NOT NULL`
  * `email` `VARCHAR(120) NOT NULL UNIQUE`
  * `date_of_birth` `DATE NOT NULL`
  * `gender` `ENUM('Male','Female','Other') NOT NULL`
  * `height_cm` `DECIMAL(5,1) NOT NULL`
  * `registration_date` `DATE NOT NULL DEFAULT (CURRENT_DATE)`
* **Integrity Constraints**:
  * `CONSTRAINT chk_user_height CHECK (height_cm > 0 AND height_cm < 280)`
  * `UNIQUE KEY (email)`

### 3.2 Table: `fitness_goals`
Maintains user-defined targets, target dates, and status transitions.
* **Columns**:
  * `goal_id` `INT AUTO_INCREMENT PRIMARY KEY`
  * `user_id` `INT NOT NULL`
  * `goal_type` `ENUM('Weight Loss','Weight Gain','Muscle Building','General Fitness','Endurance') NOT NULL`
  * `target_weight_kg` `DECIMAL(5,2)`
  * `target_calories` `INT`
  * `target_steps` `INT`
  * `target_date` `DATE`
  * `status` `ENUM('Active','Achieved','Abandoned') NOT NULL DEFAULT 'Active'`
* **Foreign Keys & Constraints**:
  * `FOREIGN KEY (user_id) REFERENCES users(user_id) ON DELETE CASCADE ON UPDATE CASCADE`
  * `CONSTRAINT chk_goal CHECK (COALESCE(target_weight_kg,1)>0 AND COALESCE(target_calories,1)>0 AND COALESCE(target_steps,0)>=0)`
* **Indexes**:
  * `INDEX idx_goal_user (user_id, status)`

### 3.3 Table: `exercises`
Master catalog of standardized exercises and muscle recruitment classifications.
* **Columns**:
  * `exercise_id` `INT AUTO_INCREMENT PRIMARY KEY`
  * `exercise_name` `VARCHAR(80) NOT NULL UNIQUE`
  * `category` `ENUM('Strength','Cardio','Flexibility','HIIT') NOT NULL`
  * `muscle_group` `VARCHAR(40) NOT NULL`
  * `description` `VARCHAR(255)`

### 3.4 Table: `workout_sessions`
Captures workout event headers, timing, and total energy expenditure.
* **Columns**:
  * `workout_id` `INT AUTO_INCREMENT PRIMARY KEY`
  * `user_id` `INT NOT NULL`
  * `workout_date` `DATE NOT NULL`
  * `start_time` `TIME NOT NULL`
  * `end_time` `TIME NOT NULL`
  * `workout_type` `VARCHAR(40) NOT NULL`
  * `calories_burned` `INT NOT NULL DEFAULT 0`
  * `notes` `VARCHAR(255)`
* **Foreign Keys & Constraints**:
  * `FOREIGN KEY (user_id) REFERENCES users(user_id) ON DELETE CASCADE ON UPDATE CASCADE`
  * `CONSTRAINT chk_ws CHECK (end_time > start_time AND calories_burned >= 0)`
* **Indexes**:
  * `INDEX idx_ws_user_date (user_id, workout_date)`
  * `INDEX idx_ws_date (workout_date)`

### 3.5 Table: `workout_exercises`
Junction entity recording individual sets, repetitions, resistance loads, and drill burn.
* **Columns**:
  * `workout_exercise_id` `INT AUTO_INCREMENT PRIMARY KEY`
  * `workout_id` `INT NOT NULL`
  * `exercise_id` `INT NOT NULL`
  * `sets` `INT`
  * `repetitions` `INT`
  * `weight_used_kg` `DECIMAL(6,2)`
  * `duration_minutes` `INT`
  * `calories_burned` `INT NOT NULL DEFAULT 0`
* **Foreign Keys & Constraints**:
  * `FOREIGN KEY (workout_id) REFERENCES workout_sessions(workout_id) ON DELETE CASCADE ON UPDATE CASCADE`
  * `FOREIGN KEY (exercise_id) REFERENCES exercises(exercise_id) ON DELETE RESTRICT ON UPDATE CASCADE`
  * `CONSTRAINT chk_we CHECK (COALESCE(sets,0)>=0 AND COALESCE(repetitions,0)>=0 AND COALESCE(weight_used_kg,0)>=0 AND COALESCE(duration_minutes,0)>=0 AND calories_burned>=0)`
* **Indexes**:
  * `INDEX idx_we_workout (workout_id)`
  * `INDEX idx_we_exercise (exercise_id)`

### 3.6 Table: `foods`
Nutritional reference database storing macro and micro composition per portion.
* **Columns**:
  * `food_id` `INT AUTO_INCREMENT PRIMARY KEY`
  * `food_name` `VARCHAR(80) NOT NULL UNIQUE`
  * `category` `VARCHAR(40) NOT NULL`
  * `serving_size` `VARCHAR(40) NOT NULL`
  * `calories` `DECIMAL(7,2) NOT NULL`
  * `protein_g` `DECIMAL(6,2) NOT NULL`
  * `carbs_g` `DECIMAL(6,2) NOT NULL`
  * `fat_g` `DECIMAL(6,2) NOT NULL`
  * `fiber_g` `DECIMAL(6,2) NOT NULL DEFAULT 0`
* **Constraints**:
  * `CONSTRAINT chk_food CHECK (calories>=0 AND protein_g>=0 AND carbs_g>=0 AND fat_g>=0 AND fiber_g>=0)`

### 3.7 Table: `nutrition_logs`
Logs consumed meals, portion counts, and immutable caloric snapshots.
* **Columns**:
  * `nutrition_log_id` `INT AUTO_INCREMENT PRIMARY KEY`
  * `user_id` `INT NOT NULL`
  * `food_id` `INT NOT NULL`
  * `log_date` `DATE NOT NULL`
  * `meal_type` `ENUM('Breakfast','Lunch','Dinner','Snack') NOT NULL`
  * `quantity` `DECIMAL(5,2) NOT NULL`
  * `total_calories` `DECIMAL(8,2) NOT NULL`
* **Foreign Keys & Constraints**:
  * `FOREIGN KEY (user_id) REFERENCES users(user_id) ON DELETE CASCADE ON UPDATE CASCADE`
  * `FOREIGN KEY (food_id) REFERENCES foods(food_id) ON DELETE RESTRICT ON UPDATE CASCADE`
  * `CONSTRAINT chk_nl CHECK (quantity > 0 AND total_calories >= 0)`
* **Indexes**:
  * `INDEX idx_nl_user_date (user_id, log_date)`
  * `INDEX idx_nl_date (log_date)`
  * `INDEX idx_nl_food (food_id)`
  * `INDEX idx_nl_covering (user_id, log_date, food_id, quantity, total_calories)`

### 3.8 Table: `health_metrics`
Time-series biometric records from sensor inputs and daily evaluations.
* **Columns**:
  * `metric_id` `INT AUTO_INCREMENT PRIMARY KEY`
  * `user_id` `INT NOT NULL`
  * `record_datetime` `DATETIME NOT NULL`
  * `weight_kg` `DECIMAL(5,2) NOT NULL`
  * `heart_rate` `INT`
  * `resting_heart_rate` `INT`
  * `steps` `INT NOT NULL DEFAULT 0`
  * `calories_burned` `INT NOT NULL DEFAULT 0`
  * `sleep_hours` `DECIMAL(4,2) NOT NULL DEFAULT 0`
* **Foreign Keys & Constraints**:
  * `FOREIGN KEY (user_id) REFERENCES users(user_id) ON DELETE CASCADE ON UPDATE CASCADE`
  * `CONSTRAINT chk_hm CHECK (weight_kg>0 AND weight_kg<500 AND COALESCE(heart_rate,40) BETWEEN 25 AND 250 AND COALESCE(resting_heart_rate,40) BETWEEN 25 AND 150 AND steps>=0 AND calories_burned>=0 AND sleep_hours BETWEEN 0 AND 24)`
* **Indexes**:
  * `INDEX idx_hm_user_dt (user_id, record_datetime)`
  * `INDEX idx_hm_dt (record_datetime)`

---

## 4. Computed Views Architecture
1. **`v_health_metrics_bmi`**: Computes Body Mass Index (BMI) dynamically by joining `health_metrics.weight_kg` with `users.height_cm`:
   $$\text{BMI} = \text{ROUND}\left(\frac{\text{weight\_kg}}{(\text{height\_cm}/100)^2}, 2\right)$$
2. **`v_workout_details`**: Flattens workout session headers with drill-level exercise details.
3. **`v_daily_nutrition`**: Aggregates daily caloric intake, protein (g), carbohydrates (g), and fat (g) grouped by `user_id` and `log_date`.
4. **`v_heart_rate_zones`**: Classifies cardiovascular strain into zones (Z0 Rest to Z5 Maximum) using age-derived maximum heart rate:
   $$\text{Max HR} = 220 - \text{TIMESTAMPDIFF(YEAR, date\_of\_birth, record\_datetime)}$$
5. **`v_macro_ratios`**: Calculates the percentage breakdown of daily energy intake derived from protein (4 kcal/g), carbohydrates (4 kcal/g), and fat (9 kcal/g).
6. **`v_strength_vs_protein`**: Employs SQL window functions to track weekly lifting volume changes ($\text{sets} \times \text{reps} \times \text{kg}$) alongside daily protein intake.

---

## 5. Triggers & Automated Consistency Handlers
* **`trg_nl_total` (BEFORE INSERT on `nutrition_logs`)**: Sets `NEW.total_calories = NEW.quantity * foods.calories`.
* **`trg_nl_total_upd` (BEFORE UPDATE on `nutrition_logs`)**: Recalculates `total_calories` whenever `quantity` or `food_id` changes.
* **`trg_we_ai` (AFTER INSERT on `workout_exercises`)**: Automatically sums drill calories and updates `workout_sessions.calories_burned`.
* **`trg_we_au` (AFTER UPDATE on `workout_exercises`)**: Recalculates session calories when drill calories or parent workout IDs change.
* **`trg_we_ad` (AFTER DELETE on `workout_exercises`)**: Deducts deleted drill calories from `workout_sessions.calories_burned`.

---

## 6. Stored Procedures
* **`sp_generate_stress_data(IN n INT)`**: Generates $N$ randomized, valid nutrition logs across all 20 users inside a single transaction to stress-test analytical views.
* **`sp_log_workout(IN p_user INT, IN p_date DATE, IN p_start TIME, IN p_end TIME, IN p_type VARCHAR(40), IN p_exercises JSON)`**: Demonstrates full ACID atomicity. Parses a JSON array of exercise drills, inserts the session header and drills, and re-computes total burned calories. An `SQLEXCEPTION` handler rolls back the entire operation if any foreign key or check constraint is violated.

---

## 7. API Integration Guide

Base URL: `http://localhost:5000` (or configured `FLASK_HOST:FLASK_PORT`). All responses are formatted in `application/json`.

### 7.1 Users API
* **`GET /users`**
  * *Description*: Retrieve all registered users.
  * *Response (200 OK)*:
    ```json
    [
      {
        "user_id": 1,
        "full_name": "Aarav Nair",
        "email": "aarav.nair@example.com",
        "date_of_birth": "1998-04-12",
        "gender": "Male",
        "height_cm": 176.0,
        "registration_date": "2026-01-05"
      }
    ]
    ```
* **`POST /users`**
  * *Request Body*:
    ```json
    {
      "full_name": "Maya Patel",
      "email": "maya.patel@example.com",
      "date_of_birth": "2000-05-15",
      "gender": "Female",
      "height_cm": 165.0
    }
    ```
  * *Response (201 Created)*: `{"user_id": 21}`
* **`PUT /users/<int:id>`**
  * *Request Body*: `{"full_name": "Maya R. Patel", "height_cm": 165.5}`
  * *Response (200 OK)*: `{"updated": 21}`
* **`DELETE /users/<int:id>`**
  * *Response (200 OK)*: `{"deleted": 21}`

---

### 7.2 Fitness Goals API
* **`GET /goals?user_id=1`**
  * *Description*: List fitness goals for a user, sorted by status and deadline, including live progress comparison with current weight.
  * *Response (200 OK)*:
    ```json
    [
      {
        "goal_id": 1,
        "user_id": 1,
        "full_name": "Aarav Nair",
        "goal_type": "Muscle Building",
        "target_weight_kg": 67.0,
        "current_weight_kg": 65.8,
        "target_calories": 1890,
        "target_steps": 8500,
        "target_date": "2026-12-31",
        "status": "Active"
      }
    ]
    ```
* **`POST /goals`**
  * *Request Body*:
    ```json
    {
      "user_id": 1,
      "goal_type": "Weight Loss",
      "target_weight_kg": 64.0,
      "target_calories": 2000,
      "target_steps": 10000,
      "target_date": "2026-12-31",
      "status": "Active"
    }
    ```
  * *Response (201 Created)*: `{"goal_id": 22}`
* **`PUT /goals/<int:id>`**
  * *Request Body*: `{"target_weight_kg": 63.5, "status": "Achieved"}`
  * *Response (200 OK)*: `{"updated": 22}`
* **`DELETE /goals/<int:id>`**
  * *Response (200 OK)*: `{"deleted": 22}`

---

### 7.3 Workouts API
* **`GET /exercises`**
  * *Description*: Return master exercise catalog.
  * *Response (200 OK)*:
    ```json
    [
      {"exercise_id": 1, "exercise_name": "Squats", "category": "Strength", "muscle_group": "Legs"}
    ]
    ```
* **`GET /workouts?user_id=1`**
  * *Response (200 OK)*:
    ```json
    [
      {
        "workout_id": 154,
        "user_id": 1,
        "workout_date": "2026-11-04",
        "start_time": "06:30:00",
        "end_time": "07:15:00",
        "workout_type": "Strength",
        "calories_burned": 330,
        "notes": "Legs and chest routine"
      }
    ]
    ```
* **`POST /workouts`**
  * *Request Body*:
    ```json
    {
      "user_id": 1,
      "workout_date": "2026-11-04",
      "start_time": "07:00:00",
      "end_time": "07:45:00",
      "workout_type": "Cardio",
      "exercises": [
        {"exercise_id": 5, "duration_minutes": 30, "calories_burned": 285}
      ]
    }
    ```
  * *Response (201 Created)*: `{"workout_id": 155}`
* **`PUT /workouts/<int:id>`** & **`DELETE /workouts/<int:id>`**

---

### 7.4 Nutrition API
* **`GET /foods`**
  * *Response (200 OK)*: List of available foods with serving sizes and macronutrients.
* **`GET /nutrition?user_id=1`**
  * *Response (200 OK)*:
    ```json
    [
      {
        "nutrition_log_id": 5301,
        "user_id": 1,
        "food_name": "Oatmeal",
        "log_date": "2026-11-04",
        "meal_type": "Breakfast",
        "quantity": 1.5,
        "total_calories": 225.0
      }
    ]
    ```
* **`POST /nutrition`**
  * *Request Body*:
    ```json
    {
      "user_id": 1,
      "food_id": 1,
      "log_date": "2026-11-04",
      "meal_type": "Breakfast",
      "quantity": 1.5
    }
    ```
  * *Response (201 Created)*: `{"nutrition_log_id": 5302}`
* **`PUT /nutrition/<int:id>`** & **`DELETE /nutrition/<int:id>`**

---

### 7.5 Health Metrics API
* **`GET /health-metrics?user_id=1`**
  * *Response (200 OK)*: Returns latest time-series records with derived BMI, heart rate, steps, and sleep.
* **`POST /health-metrics`**
  * *Request Body*:
    ```json
    {
      "user_id": 1,
      "record_datetime": "2026-11-04 07:30:00",
      "weight_kg": 65.5,
      "heart_rate": 68,
      "resting_heart_rate": 58,
      "steps": 9200,
      "calories_burned": 400,
      "sleep_hours": 7.5
    }
    ```
  * *Response (201 Created)*: `{"metric_id": 162}`

---

### 7.6 Analytics Engine Endpoints
* **`GET /analytics/calorie-balance?user_id=1`**: Unified daily caloric balance (Consumed vs Burned vs Balance).
* **`GET /analytics/weekly-progress?user_id=1`**: Workout counts and cumulative active minutes per `YEARWEEK`.
* **`GET /analytics/health-trends?user_id=1`**: Weight drift, BMI, steps, and sleep time-series.
* **`GET /analytics/nutrition-summary?user_id=1`**: Daily calorie and macro sums.
* **`GET /analytics/heart-rate-zones?user_id=1`**: Reading frequencies across physiological training zones (Z0–Z5).
* **`GET /analytics/macro-ratios?user_id=1`**: Daily percentage shares of protein, carbohydrates, and fats.
* **`GET /analytics/strength-vs-protein?user_id=1`**: Weekly resistance lifting tonnage against average daily protein intake.
