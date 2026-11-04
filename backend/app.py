"""APEX - Fitness & Wellness Tracking System REST API (Flask + SQLAlchemy Core, parameterized queries only)."""
from datetime import date
from flask import Flask, jsonify, request
from flask_cors import CORS
from sqlalchemy import create_engine, text
from sqlalchemy.exc import IntegrityError, SQLAlchemyError
from config import DATABASE_URL, FLASK_DEBUG, FLASK_HOST, FLASK_PORT

app = Flask(__name__)
CORS(app)
engine = create_engine(DATABASE_URL, pool_pre_ping=True)

def rows(sql, **p):
    with engine.connect() as c:
        return [dict(r._mapping) for r in c.execute(text(sql), p)]

def run(sql, **p):
    """Execute a write inside a transaction; returns last inserted id."""
    with engine.begin() as c:
        return c.execute(text(sql), p).lastrowid

def need(data, fields):
    missing = [f for f in fields if data.get(f) in (None, "")]
    if missing:
        raise ValueError("Missing required fields: " + ", ".join(missing))

def positive(data, fields):
    for f in fields:
        if f in data and data[f] is not None and float(data[f]) < 0:
            raise ValueError(f"{f} must not be negative")

@app.errorhandler(ValueError)
def bad_value(e): return jsonify(error=str(e)), 400
@app.errorhandler(IntegrityError)
def integrity(e): return jsonify(error="Constraint violation (duplicate, invalid reference or out-of-range value)"), 409
@app.errorhandler(SQLAlchemyError)
def db_error(e):
    print("DB ERROR:", getattr(e, "orig", e))
    return jsonify(error="Database error", detail=str(getattr(e, "orig", e))), 500
@app.errorhandler(404)
def nf(e): return jsonify(error="Not found"), 404

def one(sql, **p):
    r = rows(sql, **p)
    if not r: return None
    return r[0]

# ---------------- USERS ----------------
@app.get("/users")
def list_users(): return jsonify(rows("SELECT * FROM users ORDER BY user_id"))

@app.get("/users/<int:i>")
def get_user(i):
    u = one("SELECT * FROM users WHERE user_id=:i", i=i)
    return (jsonify(u), 200) if u else (jsonify(error="User not found"), 404)

@app.post("/users")
def add_user():
    d = request.get_json(force=True)
    need(d, ["full_name", "email", "date_of_birth", "gender", "height_cm"]); positive(d, ["height_cm"])
    if float(d["height_cm"]) <= 0: raise ValueError("height_cm must be greater than zero")
    i = run("INSERT INTO users (full_name,email,date_of_birth,gender,height_cm) VALUES (:full_name,:email,:date_of_birth,:gender,:height_cm)", **{k: d[k] for k in ["full_name","email","date_of_birth","gender","height_cm"]})
    return jsonify(user_id=i), 201

@app.put("/users/<int:i>")
def edit_user(i):
    d = request.get_json(force=True); positive(d, ["height_cm"])
    allowed = [k for k in ["full_name","email","date_of_birth","gender","height_cm"] if k in d]
    if not allowed: raise ValueError("Nothing to update")
    run("UPDATE users SET " + ",".join(f"{k}=:{k}" for k in allowed) + " WHERE user_id=:i", i=i, **{k: d[k] for k in allowed})
    return jsonify(updated=i)

@app.delete("/users/<int:i>")
def del_user(i):
    run("DELETE FROM users WHERE user_id=:i", i=i); return jsonify(deleted=i)

# ---------------- FITNESS GOALS ----------------
@app.get("/goals")
def list_goals():
    uid = request.args.get("user_id")
    sql = """
        SELECT g.*, u.full_name,
               (SELECT weight_kg FROM health_metrics WHERE user_id = g.user_id ORDER BY record_datetime DESC LIMIT 1) AS current_weight_kg
        FROM fitness_goals g
        JOIN users u USING(user_id)
    """
    if uid:
        sql += " WHERE g.user_id = :u"
    sql += " ORDER BY CASE g.status WHEN 'Active' THEN 1 WHEN 'Achieved' THEN 2 ELSE 3 END, g.target_date ASC, g.goal_id DESC"
    out = rows(sql, **({"u": uid} if uid else {}))
    return jsonify([{
        **r,
        "target_weight_kg": float(r["target_weight_kg"]) if r.get("target_weight_kg") is not None else None,
        "current_weight_kg": float(r["current_weight_kg"]) if r.get("current_weight_kg") is not None else None,
        "target_date": str(r["target_date"]) if r.get("target_date") is not None else None
    } for r in out])

@app.get("/goals/<int:i>")
def get_goal(i):
    g = one("""
        SELECT g.*, u.full_name,
               (SELECT weight_kg FROM health_metrics WHERE user_id = g.user_id ORDER BY record_datetime DESC LIMIT 1) AS current_weight_kg
        FROM fitness_goals g JOIN users u USING(user_id) WHERE g.goal_id = :i
    """, i=i)
    if not g: return jsonify(error="Goal not found"), 404
    g["target_weight_kg"] = float(g["target_weight_kg"]) if g.get("target_weight_kg") is not None else None
    g["current_weight_kg"] = float(g["current_weight_kg"]) if g.get("current_weight_kg") is not None else None
    g["target_date"] = str(g["target_date"]) if g.get("target_date") is not None else None
    return jsonify(g)

@app.post("/goals")
def add_goal():
    d = request.get_json(force=True)
    need(d, ["user_id", "goal_type"])
    positive(d, ["target_weight_kg", "target_calories", "target_steps"])
    valid_types = ('Weight Loss', 'Weight Gain', 'Muscle Building', 'General Fitness', 'Endurance')
    if d["goal_type"] not in valid_types:
        raise ValueError(f"Invalid goal_type. Must be one of: {', '.join(valid_types)}")
    status = d.get("status", "Active")
    if status not in ('Active', 'Achieved', 'Abandoned'):
        raise ValueError("Invalid status. Must be Active, Achieved, or Abandoned")
    
    i = run("""INSERT INTO fitness_goals (user_id, goal_type, target_weight_kg, target_calories, target_steps, target_date, status)
               VALUES (:user_id, :goal_type, :target_weight_kg, :target_calories, :target_steps, :target_date, :status)""",
            user_id=d["user_id"], goal_type=d["goal_type"], target_weight_kg=d.get("target_weight_kg"),
            target_calories=d.get("target_calories"), target_steps=d.get("target_steps"),
            target_date=d.get("target_date"), status=status)
    return jsonify(goal_id=i), 201

@app.put("/goals/<int:i>")
def edit_goal(i):
    d = request.get_json(force=True)
    positive(d, ["target_weight_kg", "target_calories", "target_steps"])
    allowed = ["goal_type", "target_weight_kg", "target_calories", "target_steps", "target_date", "status"]
    fields = [k for k in allowed if k in d]
    if not fields: raise ValueError("Nothing to update")
    if "goal_type" in d and d["goal_type"] not in ('Weight Loss', 'Weight Gain', 'Muscle Building', 'General Fitness', 'Endurance'):
        raise ValueError("Invalid goal_type")
    if "status" in d and d["status"] not in ('Active', 'Achieved', 'Abandoned'):
        raise ValueError("Invalid status")
    run("UPDATE fitness_goals SET " + ",".join(f"{k}=:{k}" for k in fields) + " WHERE goal_id=:i", i=i, **{k: d[k] for k in fields})
    return jsonify(updated=i)

@app.delete("/goals/<int:i>")
def del_goal(i):
    run("DELETE FROM fitness_goals WHERE goal_id=:i", i=i)
    return jsonify(deleted=i)

# ---------------- WORKOUTS ----------------
@app.get("/exercises")
def exercises(): return jsonify(rows("SELECT * FROM exercises ORDER BY exercise_name"))

@app.get("/workouts")
def list_workouts():
    sql = "SELECT ws.*, u.full_name FROM workout_sessions ws JOIN users u USING(user_id)"
    uid = request.args.get("user_id")
    out = rows(sql + (" WHERE user_id=:u" if uid else "") + " ORDER BY workout_date DESC, start_time DESC LIMIT 200", **({"u": uid} if uid else {}))
    return jsonify([{k: (str(v) if k in ("workout_date", "start_time", "end_time") else v) for k, v in r.items()} for r in out])

@app.get("/workouts/<int:i>")
def get_workout(i):
    w = one("SELECT * FROM workout_sessions WHERE workout_id=:i", i=i)
    if not w: return jsonify(error="Workout not found"), 404
    w = {k: str(v) if k in ("workout_date", "start_time", "end_time") else v for k, v in w.items()}
    w["exercises"] = rows("SELECT e.exercise_name, we.* FROM workout_exercises we JOIN exercises e USING(exercise_id) WHERE workout_id=:i", i=i)
    return jsonify(w)

@app.post("/workouts")
def add_workout():
    """Atomic: session + all exercises + calorie total in ONE transaction (all-or-nothing)."""
    d = request.get_json(force=True)
    need(d, ["user_id", "workout_date", "start_time", "end_time", "workout_type"])
    ex = d.get("exercises", [])
    for e in ex:
        need(e, ["exercise_id"]); positive(e, ["sets", "repetitions", "weight_used_kg", "duration_minutes", "calories_burned"])
    with engine.begin() as c:   # rolls back automatically on any exception
        wid = c.execute(text("INSERT INTO workout_sessions (user_id,workout_date,start_time,end_time,workout_type,notes) VALUES (:user_id,:workout_date,:start_time,:end_time,:workout_type,:notes)"),
                        {**{k: d[k] for k in ["user_id","workout_date","start_time","end_time","workout_type"]}, "notes": d.get("notes")}).lastrowid
        for e in ex:
            dur = e.get("duration_minutes") or 10
            cals = e.get("calories_burned")
            if cals is None or float(cals) == 0:
                cat_row = c.execute(text("SELECT category FROM exercises WHERE exercise_id = :eid"), {"eid": e["exercise_id"]}).scalar() or "Cardio"
                rate = {"HIIT": 11.0, "Cardio": 9.5, "Strength": 6.5, "Flexibility": 4.0}.get(cat_row, 8.0)
                cals = round(float(dur) * rate)
            c.execute(text("INSERT INTO workout_exercises (workout_id,exercise_id,sets,repetitions,weight_used_kg,duration_minutes,calories_burned) VALUES (:w,:exercise_id,:sets,:repetitions,:weight_used_kg,:duration_minutes,:calories_burned)"),
                      {"w": wid, "exercise_id": e["exercise_id"], "sets": e.get("sets"), "repetitions": e.get("repetitions"),
                       "weight_used_kg": e.get("weight_used_kg"), "duration_minutes": dur, "calories_burned": cals})
        c.execute(text("UPDATE workout_sessions SET calories_burned=(SELECT COALESCE(SUM(calories_burned),0) FROM workout_exercises WHERE workout_id=:w) WHERE workout_id=:w"), {"w": wid})
    return jsonify(workout_id=wid), 201

@app.put("/workouts/<int:i>")
def edit_workout(i):
    d = request.get_json(force=True)
    allowed = [k for k in ["workout_date","start_time","end_time","workout_type","notes"] if k in d]
    if not allowed: raise ValueError("Nothing to update")
    run("UPDATE workout_sessions SET " + ",".join(f"{k}=:{k}" for k in allowed) + " WHERE workout_id=:i", i=i, **{k: d[k] for k in allowed})
    return jsonify(updated=i)

@app.delete("/workouts/<int:i>")
def del_workout(i):
    run("DELETE FROM workout_sessions WHERE workout_id=:i", i=i); return jsonify(deleted=i)

# ---------------- NUTRITION ----------------
@app.get("/foods")
def foods(): return jsonify(rows("SELECT * FROM foods ORDER BY food_name"))

@app.get("/nutrition")
def list_nutrition():
    uid = request.args.get("user_id")
    r = rows("SELECT nl.*, f.food_name FROM nutrition_logs nl JOIN foods f USING(food_id)" + (" WHERE user_id=:u" if uid else "") + " ORDER BY log_date DESC, nutrition_log_id DESC LIMIT 200", **({"u": uid} if uid else {}))
    return jsonify([{**x, "log_date": str(x["log_date"]), "quantity": float(x["quantity"]), "total_calories": float(x["total_calories"])} for x in r])

@app.post("/nutrition")
def add_nutrition():
    d = request.get_json(force=True); need(d, ["user_id","food_id","log_date","meal_type","quantity"])
    if float(d["quantity"]) <= 0: raise ValueError("quantity must be greater than zero")
    i = run("INSERT INTO nutrition_logs (user_id,food_id,log_date,meal_type,quantity,total_calories) VALUES (:user_id,:food_id,:log_date,:meal_type,:quantity,0)", **{k: d[k] for k in ["user_id","food_id","log_date","meal_type","quantity"]})
    return jsonify(nutrition_log_id=i), 201   # trigger computes total_calories

@app.put("/nutrition/<int:i>")
def edit_nutrition(i):
    d = request.get_json(force=True)
    allowed = [k for k in ["food_id","log_date","meal_type","quantity"] if k in d]
    if not allowed: raise ValueError("Nothing to update")
    if "quantity" in d and float(d["quantity"]) <= 0: raise ValueError("quantity must be greater than zero")
    run("UPDATE nutrition_logs SET " + ",".join(f"{k}=:{k}" for k in allowed) + " WHERE nutrition_log_id=:i", i=i, **{k: d[k] for k in allowed})
    return jsonify(updated=i)

@app.delete("/nutrition/<int:i>")
def del_nutrition(i):
    run("DELETE FROM nutrition_logs WHERE nutrition_log_id=:i", i=i); return jsonify(deleted=i)

# ---------------- HEALTH METRICS ----------------
def clean_metric(r):
    return {k: (str(v) if k == "record_datetime" else float(v) if hasattr(v, "as_tuple") else v) for k, v in r.items()}

@app.get("/health-metrics")
def list_metrics():
    uid = request.args.get("user_id")
    r = rows("SELECT * FROM v_health_metrics_bmi" + (" WHERE user_id=:u" if uid else "") + " ORDER BY record_datetime DESC LIMIT 200", **({"u": uid} if uid else {}))
    return jsonify([clean_metric(x) for x in r])

@app.post("/health-metrics")
def add_metric():
    d = request.get_json(force=True); need(d, ["user_id", "record_datetime", "weight_kg"])
    positive(d, ["steps", "sleep_hours", "calories_burned"])
    if float(d["weight_kg"]) <= 0: raise ValueError("weight_kg must be greater than zero")
    if d.get("heart_rate") and not 25 <= int(d["heart_rate"]) <= 250: raise ValueError("heart_rate must be between 25 and 250")
    f = ["user_id","record_datetime","weight_kg","heart_rate","resting_heart_rate","steps","calories_burned","sleep_hours"]
    i = run("INSERT INTO health_metrics (" + ",".join(f) + ") VALUES (" + ",".join(":" + k for k in f) + ")",
            **{k: d.get(k, 0 if k in ("steps","calories_burned","sleep_hours") else None) for k in f})
    return jsonify(metric_id=i), 201

@app.put("/health-metrics/<int:i>")
def edit_metric(i):
    d = request.get_json(force=True); positive(d, ["steps", "sleep_hours"])
    allowed = [k for k in ["record_datetime","weight_kg","heart_rate","resting_heart_rate","steps","calories_burned","sleep_hours"] if k in d]
    if not allowed: raise ValueError("Nothing to update")
    run("UPDATE health_metrics SET " + ",".join(f"{k}=:{k}" for k in allowed) + " WHERE metric_id=:i", i=i, **{k: d[k] for k in allowed})
    return jsonify(updated=i)

@app.delete("/health-metrics/<int:i>")
def del_metric(i):
    run("DELETE FROM health_metrics WHERE metric_id=:i", i=i); return jsonify(deleted=i)

# ---------------- ANALYTICS ----------------
def jsonable(r): return [{k: (float(v) if hasattr(v, "as_tuple") else str(v) if hasattr(v, "isoformat") else v) for k, v in x.items()} for x in r]

@app.get("/analytics/weekly-progress")
def weekly():
    return jsonify(jsonable(rows("""SELECT YEARWEEK(workout_date,1) yr_week, COUNT(*) workouts, SUM(calories_burned) calories_burned,
        SUM(TIMESTAMPDIFF(MINUTE,start_time,end_time)) minutes FROM workout_sessions WHERE user_id=:u GROUP BY yr_week ORDER BY yr_week""", u=request.args.get("user_id", 1))))

@app.get("/analytics/nutrition-summary")
def nutrition_summary():
    return jsonify(jsonable(rows("SELECT * FROM v_daily_nutrition WHERE user_id=:u ORDER BY log_date DESC LIMIT 30", u=request.args.get("user_id", 1))))

@app.get("/analytics/calorie-balance")
def balance():
    return jsonify(jsonable(rows("""SELECT d.activity_date AS log_date,
            COALESCE(ROUND(n.calories), 0) AS consumed,
            COALESCE(w.burned, 0) AS burned,
            COALESCE(ROUND(n.calories), 0) - COALESCE(w.burned, 0) AS balance
        FROM (
            SELECT log_date AS activity_date FROM v_daily_nutrition WHERE user_id = :u
            UNION
            SELECT workout_date AS activity_date FROM workout_sessions WHERE user_id = :u
        ) d
        LEFT JOIN v_daily_nutrition n ON n.user_id = :u AND n.log_date = d.activity_date
        LEFT JOIN (
            SELECT workout_date, SUM(calories_burned) AS burned
            FROM workout_sessions
            WHERE user_id = :u
            GROUP BY workout_date
        ) w ON w.workout_date = d.activity_date
        ORDER BY d.activity_date DESC LIMIT 30""", u=request.args.get("user_id", 1))))

@app.get("/analytics/health-trends")
def trends():
    return jsonify(jsonable(rows("SELECT record_datetime, weight_kg, bmi, steps, sleep_hours FROM v_health_metrics_bmi WHERE user_id=:u ORDER BY record_datetime", u=request.args.get("user_id", 1))))

@app.get("/analytics/heart-rate-zones")
def hr_zones():
    return jsonify(jsonable(rows("""SELECT hr_zone, COUNT(*) readings, ROUND(AVG(heart_rate)) avg_hr, ROUND(AVG(pct_of_max),1) avg_pct_of_max
        FROM v_heart_rate_zones WHERE user_id=:u GROUP BY hr_zone ORDER BY hr_zone""", u=request.args.get("user_id", 1))))

@app.get("/analytics/macro-ratios")
def macro_ratios():
    return jsonify(jsonable(rows("""SELECT log_date, calories, protein_g, carbs_g, fat_g, protein_pct, carbs_pct, fat_pct
        FROM v_macro_ratios WHERE user_id=:u ORDER BY log_date DESC LIMIT 14""", u=request.args.get("user_id", 1))))

@app.get("/analytics/strength-vs-protein")
def strength_vs_protein():
    return jsonify(jsonable(rows("""SELECT yr_week, avg_daily_protein_g, strength_volume_kg, strength_change_kg, strength_change_pct
        FROM v_strength_vs_protein WHERE user_id=:u ORDER BY yr_week""", u=request.args.get("user_id", 1))))

if __name__ == "__main__":
    app.run(debug=FLASK_DEBUG, host=FLASK_HOST, port=FLASK_PORT)