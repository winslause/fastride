import uuid
import json
import datetime
import urllib.request
import urllib.parse
import bcrypt
from typing import Optional, List, Dict, Any

import psycopg2
from psycopg2.extras import RealDictCursor
from fastapi import FastAPI, Depends, HTTPException, status, Response, Query
from fastapi.security import HTTPBearer, HTTPAuthorizationCredentials
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
from jose import JWTError, jwt
from datetime import timedelta

app = FastAPI(title="FastRide API")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=False,
    allow_methods=["*"],
    allow_headers=["*"],
    expose_headers=["*"],
)

security = HTTPBearer()


DB_CONFIG = {
    "host": "127.0.0.1",
    "port": 5432,
    "user": "postgres",
    "password": "Shioso2023",
    "dbname": "fastride",
}

SECRET_KEY = "fastride-secret-key-change-in-production"
ALGORITHM = "HS256"
ACCESS_TOKEN_EXPIRE_MINUTES = 60 * 24

GEOCODER_URL = "https://photon.komoot.io"
OSRM_URL = "https://router.project-osrm.org"
SEARCH_CACHE_TTL_HOURS = 24


def get_db():
    conn = psycopg2.connect(**DB_CONFIG)
    conn.autocommit = True
    try:
        yield conn
    finally:
        conn.close()


def get_optional_db():
    try:
        conn = psycopg2.connect(**DB_CONFIG)
        conn.autocommit = True
    except Exception:
        yield None
        return
    try:
        yield conn
    finally:
        conn.close()


def hash_password(password: str) -> str:
    return bcrypt.hashpw(password.encode("utf-8"), bcrypt.gensalt()).decode("utf-8")


def verify_password(plain_password: str, hashed_password: str) -> bool:
    return bcrypt.checkpw(plain_password.encode("utf-8"), hashed_password.encode("utf-8"))


def create_access_token(data: dict, expires_delta: Optional[timedelta] = None) -> str:
    to_encode = data.copy()
    expire = datetime.datetime.utcnow() + (expires_delta or timedelta(minutes=ACCESS_TOKEN_EXPIRE_MINUTES))
    to_encode.update({"exp": expire})
    return jwt.encode(to_encode, SECRET_KEY, algorithm=ALGORITHM)


def get_current_user(
    credentials: HTTPAuthorizationCredentials = Depends(security),
    db=Depends(get_db),
):
    token = credentials.credentials
    try:
        payload = jwt.decode(token, SECRET_KEY, algorithms=[ALGORITHM])
        user_id: str = payload.get("sub")
        if user_id is None:
            raise HTTPException(status_code=401, detail="Invalid token")
    except JWTError:
        raise HTTPException(status_code=401, detail="Invalid token")
    cur = db.cursor(cursor_factory=RealDictCursor)
    cur.execute("SELECT id, full_name, phone, email, role, is_verified, created_at, updated_at FROM users WHERE id = %s", (user_id,))
    user = cur.fetchone()
    cur.close()
    if user is None:
        raise HTTPException(status_code=401, detail="User not found")
    return user


class RegisterRequest(BaseModel):
    full_name: str
    phone: str
    email: str
    password: str
    role: str = "rider"


class LoginRequest(BaseModel):
    identifier: str
    password: str
    role: Optional[str] = None


class LoginResponse(BaseModel):
    access_token: str
    token_type: str
    user: dict


@app.post("/auth/register", status_code=status.HTTP_201_CREATED)
def register(req: RegisterRequest, db=Depends(get_db)):
    cur = db.cursor(cursor_factory=RealDictCursor)
    cur.execute("SELECT id FROM users WHERE email = %s", (req.email,))
    if cur.fetchone():
        cur.close()
        raise HTTPException(status_code=400, detail="Email already registered")
    cur.execute("SELECT id FROM users WHERE phone = %s", (req.phone,))
    if cur.fetchone():
        cur.close()
        raise HTTPException(status_code=400, detail="Phone already registered")

    user_id = str(uuid.uuid4())
    hashed = hash_password(req.password)
    now = datetime.datetime.utcnow()
    cur.execute(
        """INSERT INTO users (id, full_name, phone, email, password_hash, role, is_verified, created_at, updated_at)
           VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s)""",
        (user_id, req.full_name, req.phone, req.email, hashed, req.role, False, now, now),
    )
    db.commit()

    cur.execute(
        "SELECT id, full_name, phone, email, role, is_verified, created_at, updated_at FROM users WHERE id = %s",
        (user_id,),
    )
    user = cur.fetchone()
    cur.close()

    if req.role == "driver":
        cur = db.cursor(cursor_factory=RealDictCursor)
        cur.execute(
            """INSERT INTO drivers (id, user_id, rating, total_trips, is_online, is_verified, created_at, updated_at)
               VALUES (%s, %s, %s, %s, %s, %s, %s, %s)""",
            (str(uuid.uuid4()), user_id, 5.0, 0, False, False, now, now),
        )
        db.commit()
        cur.close()

    token = create_access_token({"sub": user_id, "role": req.role})
    return {"access_token": token, "token_type": "bearer", "user": user}


@app.post("/auth/login", response_model=LoginResponse)
def login(req: LoginRequest, db=Depends(get_db)):
    cur = db.cursor(cursor_factory=RealDictCursor)
    cur.execute(
        """SELECT id, full_name, phone, email, password_hash, role, is_verified, created_at, updated_at
           FROM users WHERE email = %s OR phone = %s""",
        (req.identifier, req.identifier),
    )
    user = cur.fetchone()
    cur.close()
    if not user or not verify_password(req.password, user["password_hash"]):
        raise HTTPException(status_code=401, detail="Invalid email or password")
    token = create_access_token({"sub": user["id"], "role": user["role"]})
    user_data = {k: v for k, v in user.items() if k != "password_hash"}
    return {"access_token": token, "token_type": "bearer", "user": user_data}


@app.get("/auth/me")
def get_me(current_user: dict = Depends(get_current_user), db=Depends(get_db)):
    user_id = current_user["id"]
    cur = db.cursor(cursor_factory=RealDictCursor)
    cur.execute(
        "SELECT id, full_name, phone, email, role, is_verified, created_at, updated_at FROM users WHERE id = %s",
        (user_id,),
    )
    user = cur.fetchone()
    cur.close()
    return {"user": user}


@app.patch("/auth/profile")
def update_profile(
    full_name: Optional[str] = None,
    phone: Optional[str] = None,
    email: Optional[str] = None,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    user_id = current_user["id"]
    updates = []
    params = []
    if full_name is not None:
        updates.append("full_name = %s")
        params.append(full_name)
    if phone is not None:
        updates.append("phone = %s")
        params.append(phone)
    if email is not None:
        updates.append("email = %s")
        params.append(email)
    if updates:
        params.append(user_id)
        cur = db.cursor()
        cur.execute(f"UPDATE users SET {', '.join(updates)} WHERE id = %s", params)
        db.commit()
        cur.close()

    cur = db.cursor(cursor_factory=RealDictCursor)
    cur.execute(
        "SELECT id, full_name, phone, email, role, is_verified, created_at, updated_at FROM users WHERE id = %s",
        (user_id,),
    )
    user = cur.fetchone()
    cur.close()
    return {"user": user}


@app.post("/auth/logout")
def logout(db=Depends(get_db)):
    return {"message": "Logged out successfully"}


class PasswordRequest(BaseModel):
    current_password: str
    new_password: str


@app.patch("/auth/password")
def update_password(
    req: PasswordRequest,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    user_id = current_user["id"]
    cur = db.cursor(cursor_factory=RealDictCursor)
    cur.execute("SELECT password_hash FROM users WHERE id = %s", (user_id,))
    row = cur.fetchone()
    if not row or not verify_password(req.current_password, row["password_hash"]):
        cur.close()
        raise HTTPException(status_code=400, detail="Current password is incorrect")
    if len(req.new_password) < 6:
        cur.close()
        raise HTTPException(status_code=400, detail="New password must be at least 6 characters")
    hashed = hash_password(req.new_password)
    now = datetime.datetime.utcnow()
    cur.execute(
        "UPDATE users SET password_hash = %s, updated_at = %s WHERE id = %s",
        (hashed, now, user_id),
    )
    db.commit()
    cur.close()
    return {"message": "Password updated successfully"}


# =========================================================================
# Nearby drivers
# =========================================================================

@app.get("/drivers")
def get_drivers(
    lat: float = Query(..., ge=-90, le=90),
    lon: float = Query(..., ge=-180, le=180),
    radius_km: float = Query(default=10, ge=1, le=100),
    limit: int = Query(default=20, ge=1, le=100),
    vehicle_class: Optional[str] = Query(default=None),
    db=Depends(get_optional_db),
):
    if db is None:
        return {"drivers": [], "count": 0}

    try:
        cur = db.cursor(cursor_factory=RealDictCursor)
        query = """
            SELECT
                d.id, d.rating, d.total_trips, d.is_online, d.is_verified,
                d.latitude, d.longitude, d.last_seen,
                u.full_name, u.phone,
                v.make, v.model, v.plate_number, v.color, v.year,
                v.vehicle_class, v.seats
            FROM drivers d
            JOIN users u ON d.user_id = u.id
            LEFT JOIN vehicles v ON v.driver_id = d.id
            WHERE d.latitude IS NOT NULL
              AND d.longitude IS NOT NULL
              AND d.is_online = TRUE
              AND d.last_seen > NOW() - INTERVAL '1 hour'
        """
        params: list = []

        # Approximate distance filter using the Haversine formula
        query += (
            " AND (6371 * acos("
            " cos(radians(%s)) * cos(radians(d.latitude)) * "
            " cos(radians(d.longitude) - radians(%s)) + "
            " sin(radians(%s)) * sin(radians(d.latitude))"
            ")) <= %s"
        )
        params.extend([lat, lon, lat, radius_km])

        if vehicle_class is not None:
            query += " AND v.vehicle_class = %s"
            params.append(vehicle_class)

        query += " ORDER BY d.last_seen DESC LIMIT %s"
        params.append(limit)

        cur.execute(query, params)
        drivers = cur.fetchall()
        cur.close()
    except Exception:
        drivers = []

    # Calculate actual distance for each driver
    import math as _math

    def _haversine(lat1, lon1, lat2, lon2):
        R = 6371000  # meters
        phi1 = _math.radians(lat1)
        phi2 = _math.radians(lat2)
        delta_phi = _math.radians(lat2 - lat1)
        delta_lambda = _math.radians(lon2 - lon1)
        a = (
            _math.sin(delta_phi / 2) ** 2
            + _math.cos(phi1) * _math.cos(phi2)
            * _math.sin(delta_lambda / 2) ** 2
        )
        c = 2 * _math.atan2(_math.sqrt(a), _math.sqrt(1 - a))
        return R * c

    results = []
    for d in drivers:
        if d["latitude"] is None or d["longitude"] is None:
            continue
        dist = _haversine(lat, lon, d["latitude"], d["longitude"])
        results.append({
            "id": d["id"],
            "full_name": d["full_name"],
            "phone": d["phone"],
            "rating": d["rating"] or 0,
            "total_trips": d["total_trips"] or 0,
            "is_verified": d["is_verified"] or False,
            "latitude": d["latitude"],
            "longitude": d["longitude"],
            "distance_meters": round(dist, 1),
            "vehicle": {
                "make": d["make"] or "",
                "model": d["model"] or "",
                "plate_number": d["plate_number"] or "",
                "color": d["color"],
                "year": d["year"],
                "vehicle_class": d["vehicle_class"] or "standard",
                "seats": d["seats"] or 4,
            },
        })

    results.sort(key=lambda x: x["distance_meters"])
    return {"drivers": results, "count": len(results)}


# =========================================================================
# Search (geocoding) — proxies to Photon, cached in the `places` table.
# =========================================================================

class GeocodeResult(BaseModel):
    label: str
    primary: str
    secondary: str
    lat: float
    lng: float


@app.get("/search", response_model=List[GeocodeResult])
def search_places(
    q: str = Query(..., min_length=1, max_length=200),
    lat: Optional[float] = Query(default=None),
    lon: Optional[float] = Query(default=None),
    limit: int = Query(default=8, ge=1, le=50),
    db=Depends(get_optional_db),
):
    if len(q.strip()) < 2:
        return []

    rounded_lat = round(lat, 3) if lat is not None else None
    rounded_lng = round(lon, 3) if lon is not None else None

    cached: list = []
    if db is not None:
        try:
            cur = db.cursor(cursor_factory=RealDictCursor)
            cur.execute(
                """SELECT label, primary_text, secondary_text, lat, lng
                   FROM places
                   WHERE query = %s
                     AND lat_bias IS NOT DISTINCT FROM %s
                     AND lng_bias IS NOT DISTINCT FROM %s
                     AND source IS NOT NULL
                     AND created_at > NOW() - INTERVAL %s
                   ORDER BY created_at DESC
                   LIMIT %s""",
                (q.strip(), rounded_lat, rounded_lng,
                 f"{SEARCH_CACHE_TTL_HOURS} hours", limit),
            )
            cached = cur.fetchall()
            cur.close()
        except Exception:
            cached = []

    if cached:
        return [
            GeocodeResult(
                label=row["label"],
                primary=row["primary_text"],
                secondary=row["secondary_text"] or "",
                lat=float(row["lat"]),
                lng=float(row["lng"]),
            )
            for row in cached
        ]

    params = {
        "q": q.strip(),
        "limit": str(limit),
    }
    if rounded_lat is not None and rounded_lng is not None:
        params["lon"] = str(rounded_lng)
        params["lat"] = str(rounded_lat)

    url = f"{GEOCODER_URL}/api/?{urllib.parse.urlencode(params)}"
    results: List[GeocodeResult] = []
    try:
        req = urllib.request.Request(
            url, headers={"User-Agent": "FastRide/1.0 (backend)"}
        )
        with urllib.request.urlopen(req, timeout=10) as resp:
            data = json.loads(resp.read().decode("utf-8"))
    except Exception:
        return []

    features = data.get("features", []) if isinstance(data, dict) else []
    now = datetime.datetime.utcnow()
    for f in features:
        geometry = f.get("geometry") or {}
        coords = geometry.get("coordinates", [])
        if not isinstance(coords, (list, tuple)) or len(coords) < 2:
            continue

        lng_val = float(coords[0])
        lat_val = float(coords[1])
        props = f.get("properties", {})

        primary = (
            props.get("name")
            or props.get("street")
            or props.get("city")
            or props.get("county")
            or "Unknown place"
        )
        if not isinstance(primary, str):
            primary = str(primary)

        secondary_parts = []
        for field in ("street", "city", "town", "village", "state", "country"):
            val = props.get(field)
            if val and isinstance(val, str) and val.strip():
                if val not in secondary_parts:
                    secondary_parts.append(val)
        secondary = ", ".join(secondary_parts[:3])

        label = f"{primary} · {secondary}" if secondary else primary

        results.append(
            GeocodeResult(
                label=label,
                primary=primary,
                secondary=secondary,
                lat=lat_val,
                lng=lng_val,
            )
        )

    if results and db is not None:
        try:
            cur = db.cursor()
            for r in results:
                cur.execute(
                    """INSERT INTO places
                       (id, query, lat_bias, lng_bias, label, primary_text,
                        secondary_text, lat, lng, source, created_at)
                       VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)""",
                    (
                        str(uuid.uuid4()),
                        q.strip(),
                        rounded_lat,
                        rounded_lng,
                        r.label,
                        r.primary,
                        r.secondary,
                        r.lat,
                        r.lng,
                        "photon",
                        now,
                    ),
                )
            db.commit()
            cur.close()
        except Exception:
            pass

    return results


# =========================================================================
# Routing — proxies to OSRM and returns a normalised payload.
# =========================================================================

class RouteResponse(BaseModel):
    distance_meters: float
    duration_seconds: float
    polyline: List[dict]
    segments: List[dict] = []


class LocationRequest(BaseModel):
    lat: float
    lng: float
    accuracy: Optional[float] = None


@app.post("/location")
def save_location(
    req: LocationRequest,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_optional_db),
):
    user_id = current_user["id"]
    now = datetime.datetime.utcnow()

    if db is not None:
        try:
            cur = db.cursor()
            cur.execute(
                """INSERT INTO user_locations
                   (id, user_id, lat, lng, accuracy, updated_at)
                   VALUES (%s, %s, %s, %s, %s, %s)""",
                (
                    str(uuid.uuid4()),
                    user_id,
                    req.lat,
                    req.lng,
                    req.accuracy,
                    now,
                ),
            )
            db.commit()
            cur.close()
        except Exception:
            pass

    return {"message": "Location saved", "lat": req.lat, "lng": req.lng}


@app.get("/route", response_model=RouteResponse)
def route(
    from_lat: float = Query(..., ge=-90, le=90),
    from_lng: float = Query(..., ge=-180, le=180),
    to_lat: float = Query(..., ge=-90, le=90),
    to_lng: float = Query(..., ge=-180, le=180),
    profile: str = Query(default="driving"),
):
    coords = (
        f"{from_lng:.6f},{from_lat:.6f};"
        f"{to_lng:.6f},{to_lat:.6f}"
    )
    url = (
        f"{OSRM_URL}/route/v1/{profile}/{coords}"
        "?overview=full&geometries=geojson&steps=true"
        "&annotations=duration,distance"
    )

    try:
        req = urllib.request.Request(
            url, headers={"User-Agent": "FastRide/1.0 (backend)"}
        )
        with urllib.request.urlopen(req, timeout=10) as resp:
            data = json.loads(resp.read().decode("utf-8"))
    except Exception:
        raise HTTPException(
            status_code=502, detail="Routing service unavailable"
        )

    if data.get("code") != "Ok":
        raise HTTPException(
            status_code=404, detail="No route found between the selected points"
        )

    routes = data.get("routes", [])
    if not routes:
        raise HTTPException(
            status_code=404, detail="No route found between the selected points"
        )

    first = routes[0]
    geometry = first.get("geometry", {})
    coords_list = geometry.get("coordinates", [])

    polyline = []
    for c in coords_list:
        if isinstance(c, (list, tuple)) and len(c) >= 2:
            polyline.append({"lat": float(c[1]), "lng": float(c[0])})

    # Build segment-level data for traffic visualization
    segments = []
    legs = first.get("legs", [])
    for leg in legs:
        leg_dur = float(leg.get("duration", 0))
        leg_dist = float(leg.get("distance", 0))
        leg_steps = leg.get("steps", [])
        if leg_steps:
            for step in leg_steps:
                step_dur = float(step.get("duration", 0))
                step_dist = float(step.get("distance", 0))
                step_geom = step.get("geometry", {})
                step_coords = step_geom.get("coordinates", [])
                step_points = []
                for c in step_coords:
                    if isinstance(c, (list, tuple)) and len(c) >= 2:
                        step_points.append({"lat": float(c[1]), "lng": float(c[0])})
                speed = step_dist / step_dur if step_dur > 0 else 0
                segments.append({
                    "distance_meters": step_dist,
                    "duration_seconds": step_dur,
                    "avg_speed_kmh": speed * 3.6 if speed > 0 else 0,
                    "polyline": step_points,
                    "maneuver": step.get("maneuver", {}).get("instruction", ""),
                })
        else:
            # Fallback: if no steps, use leg-level annotations
            annotations = leg.get("annotation", {})
            dur_list = annotations.get("duration", [])
            dist_list = annotations.get("distance", [])
            node_coords = annotations.get("nodes", [])
            for idx in range(len(dur_list)):
                step_dur = float(dur_list[idx])
                step_dist = float(dist_list[idx]) if idx < len(dist_list) else 0
                speed = step_dist / step_dur if step_dur > 0 else 0
                segments.append({
                    "distance_meters": step_dist,
                    "duration_seconds": step_dur,
                    "avg_speed_kmh": speed * 3.6 if speed > 0 else 0,
                    "polyline": [],
                    "maneuver": "",
                })

    return RouteResponse(
        distance_meters=float(first.get("distance", 0)),
        duration_seconds=float(first.get("duration", 0)),
        polyline=polyline,
        segments=segments,
    )


# =========================================================================
# Ride history
# =========================================================================

class RideResponse(BaseModel):
    id: str
    state: str
    fare_estimate: Optional[float] = None
    fare_final: Optional[float] = None
    currency: str
    distance_meters: Optional[float] = None
    duration_seconds: Optional[float] = None
    pickup_place: Optional[str] = None
    dropoff_place: Optional[str] = None
    requested_at: Optional[str] = None
    completed_at: Optional[str] = None
    cancelled_at: Optional[str] = None
    driver_name: Optional[str] = None
    driver_rating: Optional[float] = None


@app.get("/rides", response_model=List[RideResponse])
def get_rides(
    current_user: dict = Depends(get_current_user),
    db=Depends(get_optional_db),
    limit: int = Query(default=50, ge=1, le=100),
    status: Optional[str] = Query(default=None),
):
    user_id = current_user["id"]
    if db is None:
        return []

    try:
        cur = db.cursor(cursor_factory=RealDictCursor)
        query = """
            SELECT
                r.id, r.state, r.fare_estimate, r.fare_final, r.currency,
                r.distance_meters, r.duration_seconds,
                r.pickup_place, r.dropoff_place,
                r.requested_at, r.completed_at, r.cancelled_at,
                u.full_name AS driver_name, d.rating AS driver_rating
            FROM rides r
            LEFT JOIN drivers d ON r.driver_id = d.id
            LEFT JOIN users u ON d.user_id = u.id
            WHERE r.rider_id = %s
        """
        params: list = [user_id]

        if status is not None:
            query += " AND r.state = %s"
            params.append(status)

        query += " ORDER BY r.created_at DESC LIMIT %s"
        params.append(limit)

        cur.execute(query, params)
        rides = cur.fetchall()
        cur.close()
    except Exception:
        return []

    results = []
    for r in rides:
        results.append({
            "id": r["id"],
            "state": r["state"],
            "fare_estimate": r["fare_estimate"],
            "fare_final": r["fare_final"],
            "currency": r["currency"] or "KES",
            "distance_meters": r["distance_meters"],
            "duration_seconds": r["duration_seconds"],
            "pickup_place": r["pickup_place"],
            "dropoff_place": r["dropoff_place"],
            "requested_at": r["requested_at"].isoformat() if r["requested_at"] else None,
            "completed_at": r["completed_at"].isoformat() if r["completed_at"] else None,
            "cancelled_at": r["cancelled_at"].isoformat() if r["cancelled_at"] else None,
            "driver_name": r["driver_name"],
            "driver_rating": r["driver_rating"],
        })

    return results