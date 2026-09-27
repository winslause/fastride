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
from pydantic import BaseModel, model_validator
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
    email: Optional[str] = None
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
    email = req.email if req.email and req.email.strip() else None
    cur.execute("SELECT id FROM users WHERE email = %s", (email,))
    if email and cur.fetchone():
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
        (user_id, req.full_name, req.phone, email, hashed, req.role, False, now, now),
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


class ProfileUpdateRequest(BaseModel):
    full_name: Optional[str] = None
    phone: Optional[str] = None
    email: Optional[str] = None


@app.patch("/auth/profile")
def update_profile(
    req: ProfileUpdateRequest,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    user_id = current_user["id"]
    updates = []
    params = []
    if req.full_name is not None:
        updates.append("full_name = %s")
        params.append(req.full_name)
    if req.phone is not None:
        updates.append("phone = %s")
        params.append(req.phone)
    if req.email is not None:
        updates.append("email = %s")
        params.append(req.email)
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
    trip_distance_meters: Optional[float] = Query(default=None, ge=0),
    trip_duration_seconds: Optional[float] = Query(default=None, ge=0),
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
                d.base_fare, d.price_per_km, d.price_per_minute,
                d.minimum_fare, d.currency,
                u.full_name, u.phone,
                v.make, v.model, v.plate_number, v.color, v.year,
                v.vehicle_class, v.seats
            FROM drivers d
            JOIN users u ON d.user_id = u.id
            LEFT JOIN vehicles v ON v.driver_id = d.id
            WHERE d.latitude IS NOT NULL
              AND d.longitude IS NOT NULL
              AND d.is_online = TRUE
              AND d.last_seen > (NOW() AT TIME ZONE 'UTC') - INTERVAL '1 hour'
              AND NOT EXISTS (
                  SELECT 1 FROM rides busy
                  WHERE busy.driver_id = d.id
                    AND busy.state IN (
                        'requested', 'matching', 'accepted',
                        'driver_arriving', 'driver_arrived', 'ongoing'
                    )
              )
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
        pricing = {
            "base_fare": float(d.get("base_fare") or 0),
            "price_per_km": float(d.get("price_per_km") or 0),
            "price_per_minute": float(d.get("price_per_minute") or 0),
            "minimum_fare": float(d.get("minimum_fare") or 0),
            "currency": d.get("currency") or "KES",
        }
        entry = {
            "id": d["id"],
            "full_name": d["full_name"],
            "phone": d["phone"],
            "rating": d["rating"] or 0,
            "total_trips": d["total_trips"] or 0,
            "is_verified": d["is_verified"] or False,
            "latitude": d["latitude"],
            "longitude": d["longitude"],
            "distance_meters": round(dist, 1),
            "pricing": pricing,
            "vehicle": {
                "make": d["make"] or "",
                "model": d["model"] or "",
                "plate_number": d["plate_number"] or "",
                "color": d["color"],
                "year": d["year"],
                "vehicle_class": d["vehicle_class"] or "standard",
                "seats": d["seats"] or 4,
            },
        }
        if trip_distance_meters is not None:
            breakdown = _fare_breakdown(
                pricing, trip_distance_meters, trip_duration_seconds
            )
            entry["fare_breakdown"] = breakdown
            entry["fare_estimate"] = breakdown["total"]
        results.append(entry)

    results.sort(key=lambda x: x["distance_meters"])
    return {"drivers": results, "count": len(results)}


# =========================================================================
# Driver self-service
# -------------------------------------------------------------------------
# Everything the driver app needs about "me": online status, profile
# stats, the cars they drive and the services they offer.
# =========================================================================

class DriverStatusRequest(BaseModel):
    is_online: bool
    lat: Optional[float] = None
    lng: Optional[float] = None


class VehicleRequest(BaseModel):
    make: str = ""
    model: str = ""
    plate_number: str = ""
    plate: Optional[str] = None
    color: Optional[str] = None
    year: Optional[int] = None
    vehicle_class: str = "standard"
    seats: int = 4
    photo_url: Optional[str] = None
    is_default: bool = False

    @model_validator(mode="after")
    def _normalise(self):
        # Older app builds sent the plate under `plate`; accept both.
        if not self.plate_number.strip() and self.plate:
            self.plate_number = self.plate
        if not self.make.strip():
            raise ValueError("make is required")
        if not self.model.strip():
            raise ValueError("model is required")
        if not self.plate_number.strip():
            raise ValueError("plate_number is required")
        return self


class DriverServiceRequest(BaseModel):
    name: str
    description: Optional[str] = None
    price: Optional[float] = None
    currency: str = "KES"
    duration_minutes: Optional[int] = None
    icon: Optional[str] = None
    is_active: bool = True


class DriverPricingRequest(BaseModel):
    base_fare: float = 50.0
    price_per_km: float = 25.0
    price_per_minute: float = 3.0
    minimum_fare: float = 100.0
    currency: str = "KES"

    @model_validator(mode="after")
    def _check(self):
        if self.base_fare < 0:
            raise ValueError("base_fare cannot be negative")
        if self.price_per_km < 0:
            raise ValueError("price_per_km cannot be negative")
        if self.price_per_minute < 0:
            raise ValueError("price_per_minute cannot be negative")
        if self.minimum_fare < 0:
            raise ValueError("minimum_fare cannot be negative")
        return self


DEFAULT_BASE_FARE = 50.0
DEFAULT_PRICE_PER_KM = 25.0
DEFAULT_PRICE_PER_MINUTE = 3.0
DEFAULT_MINIMUM_FARE = 100.0


def _quote_fare(pricing: dict, distance_meters: float, duration_seconds: float) -> float:
    """Fare for a trip using a driver's own rate card.

    Mirrors the client-side calculation in `FareCalculator` so the amount the
    driver sees on an offer matches what the rider is charged.
    """
    km = max(float(distance_meters or 0), 0) / 1000.0
    minutes = max(float(duration_seconds or 0), 0) / 60.0
    total = (
        float(pricing.get("base_fare") or 0)
        + km * float(pricing.get("price_per_km") or 0)
        + minutes * float(pricing.get("price_per_minute") or 0)
    )
    minimum = float(pricing.get("minimum_fare") or 0)
    return round(max(total, minimum) if minimum else total, 2)


def _require_driver(current_user: dict, db) -> dict:
    """Resolve the `drivers` row for the authenticated user, or 403."""
    cur = db.cursor(cursor_factory=RealDictCursor)
    cur.execute(
        """SELECT d.*, u.full_name, u.phone, u.email
           FROM drivers d
           JOIN users u ON u.id = d.user_id
           WHERE d.user_id = %s""",
        (current_user["id"],),
    )
    row = cur.fetchone()
    cur.close()
    if row is None:
        raise HTTPException(status_code=403, detail="Not a driver account")
    return row


def _serialize_vehicle(row: dict) -> dict:
    return {
        "id": row["id"],
        "make": row["make"] or "",
        "model": row["model"] or "",
        "plate_number": row["plate_number"] or "",
        "color": row["color"],
        "year": row["year"],
        "vehicle_class": row["vehicle_class"] or "standard",
        "seats": row["seats"] or 4,
        "photo_url": row["photo_url"],
        "is_default": bool(row.get("is_default", False)),
        "is_active": bool(row.get("is_active", True)),
    }


def _serialize_service(row: dict) -> dict:
    return {
        "id": row["id"],
        "name": row["name"],
        "description": row["description"],
        "price": row["price"],
        "currency": row["currency"] or "KES",
        "duration_minutes": row["duration_minutes"],
        "icon": row["icon"],
        "is_active": bool(row["is_active"]),
        "created_at": row["created_at"].isoformat() if row.get("created_at") else None,
    }


@app.post("/drivers/me/status")
def set_driver_status(
    req: DriverStatusRequest,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    """Flip the driver online/offline flag and refresh their last position."""
    driver = _require_driver(current_user, db)
    now = datetime.datetime.utcnow()

    cur = db.cursor()
    cur.execute(
        """UPDATE drivers
           SET is_online = %s,
               latitude = COALESCE(%s, latitude),
               longitude = COALESCE(%s, longitude),
               last_seen = %s,
               updated_at = %s
           WHERE id = %s""",
        (req.is_online, req.lat, req.lng, now, now, driver["id"]),
    )
    db.commit()
    cur.close()

    return {
        "is_online": req.is_online,
        "latitude": req.lat if req.lat is not None else driver["latitude"],
        "longitude": req.lng if req.lng is not None else driver["longitude"],
        "last_seen": now.isoformat(),
    }


@app.get("/drivers/me/pricing")
def get_driver_pricing(
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    """The driver's own rate card."""
    driver = _require_driver(current_user, db)
    return {
        "base_fare": float(driver.get("base_fare") or 0),
        "price_per_km": float(driver.get("price_per_km") or 0),
        "price_per_minute": float(driver.get("price_per_minute") or 0),
        "minimum_fare": float(driver.get("minimum_fare") or 0),
        "currency": driver.get("currency") or "KES",
    }


@app.patch("/drivers/me/pricing")
def update_driver_pricing(
    req: DriverPricingRequest,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    """Update the driver's rate card, and preview the resulting fares.

    The preview lets the driver sanity-check a change before it affects the
    fares riders are quoted.
    """
    driver = _require_driver(current_user, db)
    now = datetime.datetime.utcnow()

    cur = db.cursor()
    cur.execute(
        """UPDATE drivers
           SET base_fare = %s, price_per_km = %s, price_per_minute = %s,
               minimum_fare = %s, currency = %s, updated_at = %s
           WHERE id = %s""",
        (
            req.base_fare,
            req.price_per_km,
            req.price_per_minute,
            req.minimum_fare,
            req.currency.strip().upper()[:10] or "KES",
            now,
            driver["id"],
        ),
    )
    db.commit()
    cur.close()

    pricing = {
        "base_fare": req.base_fare,
        "price_per_km": req.price_per_km,
        "price_per_minute": req.price_per_minute,
        "minimum_fare": req.minimum_fare,
        "currency": req.currency,
    }
    return {
        "message": "Pricing updated",
        "pricing": pricing,
        "examples": {
            str(km): _quote_fare(pricing, km * 1000, 0)
            for km in (1, 5, 10, 25)
        },
    }


@app.get("/drivers/me")
def get_driver_profile(    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    """Driver dashboard payload: identity, rating, trip counts, cars, services."""
    driver = _require_driver(current_user, db)
    driver_id = driver["id"]
    cur = db.cursor(cursor_factory=RealDictCursor)

    cur.execute(
        "SELECT * FROM vehicles WHERE driver_id = %s ORDER BY is_default DESC, created_at NULLS LAST",
        (driver_id,),
    )
    vehicles = [_serialize_vehicle(r) for r in cur.fetchall()]

    cur.execute(
        """SELECT * FROM driver_services
           WHERE driver_id = %s
           ORDER BY is_active DESC, created_at DESC""",
        (driver_id,),
    )
    services = [_serialize_service(r) for r in cur.fetchall()]

    # Trip statistics — the ride history the app shows on "My rides".
    cur.execute(
        """SELECT
               COUNT(*) FILTER (WHERE state = 'completed') AS total_completed,
               COUNT(*) FILTER (
                   WHERE state = 'completed'
                     AND completed_at::date = (NOW() AT TIME ZONE 'UTC')::date
               ) AS today_completed,
               COALESCE(SUM(fare_final) FILTER (
                   WHERE state = 'completed'
                     AND completed_at::date = (NOW() AT TIME ZONE 'UTC')::date
               ), 0) AS today_earnings,
               COALESCE(SUM(fare_final) FILTER (WHERE state = 'completed'), 0) AS lifetime_earnings
           FROM rides
           WHERE driver_id = %s""",
        (driver_id,),
    )
    stats = cur.fetchone() or {}
    cur.close()

    total_completed = int(stats.get("total_completed") or 0)
    today_completed = int(stats.get("today_completed") or 0)
    today_earnings = float(stats.get("today_earnings") or 0)
    lifetime_earnings = float(stats.get("lifetime_earnings") or 0)

    return {
        "driver": {
            "id": driver_id,
            "user_id": driver["user_id"],
            "full_name": driver["full_name"],
            "phone": driver["phone"],
            "email": driver["email"],
            "rating": float(driver["rating"] or 5.0),
            "total_trips": int(driver["total_trips"] or total_completed),
            "is_online": bool(driver["is_online"]),
            "is_verified": bool(driver["is_verified"]),
            "latitude": driver["latitude"],
            "longitude": driver["longitude"],
            "last_seen": driver["last_seen"].isoformat() if driver.get("last_seen") else None,
        },
        "pricing": {
            "base_fare": float(driver.get("base_fare") or 0),
            "price_per_km": float(driver.get("price_per_km") or 0),
            "price_per_minute": float(driver.get("price_per_minute") or 0),
            "minimum_fare": float(driver.get("minimum_fare") or 0),
            "currency": driver.get("currency") or "KES",
        },
        "stats": {
            "total_rides": max(int(driver["total_trips"] or 0), total_completed),
            "today_rides": today_completed,
            "today_earnings": round(today_earnings, 2),
            "lifetime_earnings": round(lifetime_earnings, 2),
            "avg_per_ride": round(lifetime_earnings / total_completed, 2)
            if total_completed
            else 0.0,
        },
        "vehicles": vehicles,
        "services": services,
    }


# -------------------------------------------------------------------------
# Vehicles — "manage cars"
# -------------------------------------------------------------------------

@app.get("/drivers/me/vehicles")
def list_driver_vehicles(
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    driver = _require_driver(current_user, db)
    cur = db.cursor(cursor_factory=RealDictCursor)
    cur.execute(
        "SELECT * FROM vehicles WHERE driver_id = %s ORDER BY is_default DESC, created_at NULLS LAST",
        (driver["id"],),
    )
    rows = [_serialize_vehicle(r) for r in cur.fetchall()]
    cur.close()
    return {"vehicles": rows, "count": len(rows)}


@app.post("/drivers/me/vehicles", status_code=status.HTTP_201_CREATED)
def create_driver_vehicle(
    req: VehicleRequest,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    driver = _require_driver(current_user, db)
    vehicle_id = str(uuid.uuid4())
    now = datetime.datetime.utcnow()

    cur = db.cursor()
    if req.is_default:
        cur.execute(
            "UPDATE vehicles SET is_default = FALSE WHERE driver_id = %s",
            (driver["id"],),
        )
    cur.execute(
        """INSERT INTO vehicles
           (id, driver_id, make, model, plate_number, color, year,
            vehicle_class, seats, photo_url, is_default, is_active,
            created_at, updated_at)
           VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, TRUE, %s, %s)""",
        (
            vehicle_id,
            driver["id"],
            req.make.strip(),
            req.model.strip(),
            req.plate_number.strip().upper(),
            (req.color or "").strip() or None,
            req.year,
            req.vehicle_class,
            req.seats,
            req.photo_url,
            req.is_default,
            now,
            now,
        ),
    )
    db.commit()
    cur.close()
    return {"id": vehicle_id, "message": "Vehicle added"}


@app.patch("/drivers/me/vehicles/{vehicle_id}")
def update_driver_vehicle(
    vehicle_id: str,
    req: VehicleRequest,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    driver = _require_driver(current_user, db)
    now = datetime.datetime.utcnow()

    cur = db.cursor()
    if req.is_default:
        cur.execute(
            "UPDATE vehicles SET is_default = FALSE WHERE driver_id = %s",
            (driver["id"],),
        )
    cur.execute(
        """UPDATE vehicles
           SET make = %s, model = %s, plate_number = %s, color = %s, year = %s,
               vehicle_class = %s, seats = %s, photo_url = %s, is_default = %s,
               updated_at = %s
           WHERE id = %s AND driver_id = %s""",
        (
            req.make.strip(),
            req.model.strip(),
            req.plate_number.strip().upper(),
            (req.color or "").strip() or None,
            req.year,
            req.vehicle_class,
            req.seats,
            req.photo_url,
            req.is_default,
            now,
            vehicle_id,
            driver["id"],
        ),
    )
    if cur.rowcount == 0:
        cur.close()
        raise HTTPException(status_code=404, detail="Vehicle not found")
    db.commit()
    cur.close()
    return {"id": vehicle_id, "message": "Vehicle updated"}


@app.delete("/drivers/me/vehicles/{vehicle_id}")
def delete_driver_vehicle(
    vehicle_id: str,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    driver = _require_driver(current_user, db)
    cur = db.cursor()
    cur.execute(
        "DELETE FROM vehicles WHERE id = %s AND driver_id = %s",
        (vehicle_id, driver["id"]),
    )
    if cur.rowcount == 0:
        cur.close()
        raise HTTPException(status_code=404, detail="Vehicle not found")
    db.commit()
    cur.close()
    return {"message": "Vehicle removed"}


# -------------------------------------------------------------------------
# Services — what the driver offers on top of a standard ride
# -------------------------------------------------------------------------

@app.get("/drivers/me/services")
def list_driver_services(
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    driver = _require_driver(current_user, db)
    cur = db.cursor(cursor_factory=RealDictCursor)
    cur.execute(
        """SELECT * FROM driver_services
           WHERE driver_id = %s
           ORDER BY is_active DESC, created_at DESC""",
        (driver["id"],),
    )
    rows = [_serialize_service(r) for r in cur.fetchall()]
    cur.close()
    return {"services": rows, "count": len(rows)}


@app.post("/drivers/me/services", status_code=status.HTTP_201_CREATED)
def create_driver_service(
    req: DriverServiceRequest,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    driver = _require_driver(current_user, db)
    if not req.name.strip():
        raise HTTPException(status_code=400, detail="Service name is required")

    service_id = str(uuid.uuid4())
    now = datetime.datetime.utcnow()
    cur = db.cursor()
    cur.execute(
        """INSERT INTO driver_services
           (id, driver_id, name, description, price, currency,
            duration_minutes, icon, is_active, created_at, updated_at)
           VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)""",
        (
            service_id,
            driver["id"],
            req.name.strip(),
            (req.description or "").strip() or None,
            req.price,
            req.currency,
            req.duration_minutes,
            (req.icon or "").strip() or None,
            req.is_active,
            now,
            now,
        ),
    )
    db.commit()
    cur.close()
    return {"id": service_id, "message": "Service added"}


@app.patch("/drivers/me/services/{service_id}")
def update_driver_service(
    service_id: str,
    req: DriverServiceRequest,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    driver = _require_driver(current_user, db)
    cur = db.cursor()
    cur.execute(
        """UPDATE driver_services
           SET name = %s, description = %s, price = %s, currency = %s,
               duration_minutes = %s, icon = %s, is_active = %s, updated_at = %s
           WHERE id = %s AND driver_id = %s""",
        (
            req.name.strip(),
            (req.description or "").strip() or None,
            req.price,
            req.currency,
            req.duration_minutes,
            (req.icon or "").strip() or None,
            req.is_active,
            datetime.datetime.utcnow(),
            service_id,
            driver["id"],
        ),
    )
    if cur.rowcount == 0:
        cur.close()
        raise HTTPException(status_code=404, detail="Service not found")
    db.commit()
    cur.close()
    return {"id": service_id, "message": "Service updated"}


@app.delete("/drivers/me/services/{service_id}")
def delete_driver_service(
    service_id: str,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    driver = _require_driver(current_user, db)
    cur = db.cursor()
    cur.execute(
        "DELETE FROM driver_services WHERE id = %s AND driver_id = %s",
        (service_id, driver["id"]),
    )
    if cur.rowcount == 0:
        cur.close()
        raise HTTPException(status_code=404, detail="Service not found")
    db.commit()
    cur.close()
    return {"message": "Service removed"}


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
            # Keep the driver row in sync so riders searching for nearby
            # drivers see the live position of anyone who is online.
            cur.execute(
                """UPDATE drivers
                   SET latitude = %s, longitude = %s, last_seen = %s, updated_at = %s
                   WHERE user_id = %s""",
                (req.lat, req.lng, now, now, user_id),
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
# =========================================================================
# Driver rides — history + rider contact for an offer
# =========================================================================

@app.get("/drivers/me/rides")
def get_driver_rides(
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
    limit: int = Query(default=50, ge=1, le=100),
):
    """Ride history for the signed-in driver, newest first."""
    driver = _require_driver(current_user, db)
    cur = db.cursor(cursor_factory=RealDictCursor)
    cur.execute(
        """SELECT r.id, r.state, r.fare_estimate, r.fare_final, r.currency,
                  r.distance_meters, r.duration_seconds,
                  r.pickup_place, r.dropoff_place,
                  r.pickup_lat, r.pickup_lng,
                  r.dropoff_lat, r.dropoff_lng,
                  r.vehicle_class,
                  r.requested_at, r.completed_at, r.cancelled_at,
                  u.full_name AS rider_name
           FROM rides r
           LEFT JOIN users u ON u.id = r.rider_id
           WHERE r.driver_id = %s
           ORDER BY r.created_at DESC
           LIMIT %s""",
        (driver["id"], limit),
    )
    rows = cur.fetchall()
    cur.close()

    rides = []
    for r in rows:
        rides.append({
            "id": r["id"],
            "state": r["state"],
            "rider_id": None,
            "driver_id": driver["id"],
            "vehicle_class": r["vehicle_class"] or "standard",
            "fare_estimate": r["fare_estimate"],
            "fare_final": r["fare_final"],
            "currency": r["currency"] or "KES",
            "distance_meters": r["distance_meters"],
            "duration_seconds": r["duration_seconds"],
            "pickup": {
                "lat": r["pickup_lat"] or 0.0,
                "lng": r["pickup_lng"] or 0.0,
                "address": r["pickup_place"] or "",
                "place_name": r["pickup_place"] or "",
            },
            "dropoff": {
                "lat": r["dropoff_lat"] or 0.0,
                "lng": r["dropoff_lng"] or 0.0,
                "address": r["dropoff_place"] or "",
                "place_name": r["dropoff_place"] or "",
            },
            "rider": {
                "id": None,
                "full_name": r["rider_name"] or "Rider",
            },
            "requested_at": r["requested_at"].isoformat() if r["requested_at"] else None,
            "completed_at": r["completed_at"].isoformat() if r["completed_at"] else None,
            "cancelled_at": r["cancelled_at"].isoformat() if r["cancelled_at"] else None,
        })
    return {"rides": rides, "count": len(rides)}


@app.get("/rides/{ride_id}/brief")
def get_ride_brief(
    ride_id: str,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    """Full offer detail for a driver, including how to reach the rider.

    A driver may read a ride that is assigned to them, or one that is still
    open for offers.
    """
    cur = db.cursor(cursor_factory=RealDictCursor)
    cur.execute(
        """SELECT r.*, u.full_name AS rider_name, u.phone AS rider_phone
           FROM rides r
           LEFT JOIN users u ON u.id = r.rider_id
           WHERE r.id = %s""",
        (ride_id,),
    )
    ride = cur.fetchone()
    if ride is None:
        cur.close()
        raise HTTPException(status_code=404, detail="Ride not found")

    # Authorisation: the requesting user must be a driver, and must either
    # own this ride or be looking at a ride that is still open.
    # The rate card is selected here too: it is read a few lines below to
    # quote the fare, and fetching only the id left every rate at 0.
    cur.execute(
        """SELECT id, base_fare, price_per_km, price_per_minute, minimum_fare,
                  currency
           FROM drivers
           WHERE user_id = %s""",
        (current_user["id"],),
    )
    driver_row = cur.fetchone()
    cur.close()

    if driver_row is None:
        raise HTTPException(status_code=403, detail="Not a driver account")

    driver_id = driver_row["id"]
    is_open = ride["state"] in ("requested", "matching")
    if ride["driver_id"] != driver_id and not is_open:
        raise HTTPException(status_code=403, detail="Ride is assigned to another driver")

    # Quote the trip with this driver's own rate card so the amount shown on
    # the offer is the amount the rider is charged. Fall back to the platform
    # defaults so an unconfigured driver never quotes a ride at zero.
    pricing = {
        "base_fare": float(driver_row["base_fare"] or DEFAULT_BASE_FARE),
        "price_per_km": float(driver_row["price_per_km"] or DEFAULT_PRICE_PER_KM),
        "price_per_minute": float(
            driver_row["price_per_minute"] or DEFAULT_PRICE_PER_MINUTE
        ),
        "minimum_fare": float(driver_row["minimum_fare"] or DEFAULT_MINIMUM_FARE),
        "currency": driver_row["currency"] or "KES",
    }
    quoted = _quote_fare(
        pricing,
        ride["distance_meters"] or 0,
        ride["duration_seconds"] or 0,
    )
    stored = ride["fare_final"] if ride["fare_final"] is not None else ride["fare_estimate"]
    fare = quoted if quoted > 0 else float(stored or 0)

    return {
        "id": ride["id"],
        "state": ride["state"],
        "currency": ride["currency"] or pricing["currency"],
        "distance_meters": ride["distance_meters"],
        "duration_seconds": ride["duration_seconds"],
        "fare": fare,
        "quoted_fare": quoted,
        "pricing": pricing,
        "otp": ride["otp"],
        "rider": {
            "id": ride["rider_id"],
            "full_name": ride["rider_name"],
            "phone": ride["rider_phone"],
        },
        "pickup": {
            "lat": ride["pickup_lat"],
            "lng": ride["pickup_lng"],
            "address": ride["pickup_place"] or "",
            "place_name": ride["pickup_place"] or "",
        },
        "dropoff": {
            "lat": ride["dropoff_lat"],
            "lng": ride["dropoff_lng"],
            "address": ride["dropoff_place"] or "",
            "place_name": ride["dropoff_place"] or "",
        },
    }


# =========================================================================
# Ride dispatch
# -------------------------------------------------------------------------
# The rider picks a driver from the list of drivers who are online, the ride
# is written against that driver with a fare quoted from that driver's own
# rate card, and the driver app picks it up on their next poll.
# =========================================================================

OFFER_STATES = ("requested", "matching")
OFFER_TTL_SECONDS = 90
ACTIVE_RIDE_STATES = (
    "requested",
    "matching",
    "accepted",
    "driver_arriving",
    "driver_arrived",
    "ongoing",
)


class RideRequestIn(BaseModel):
    pickup: dict
    dropoff: dict
    vehicle_class: str = "standard"
    distance_meters: float = 0
    duration_seconds: float = 0
    driver_id: Optional[str] = None
    currency: str = "KES"


class RideStateIn(BaseModel):
    state: str
    reason: Optional[str] = None


def _new_otp() -> str:
    return f"{uuid.uuid4().int % 10000:04d}"


def _pricing_row(row: dict) -> dict:
    return {
        "base_fare": float(row.get("base_fare") or 0),
        "price_per_km": float(row.get("price_per_km") or 0),
        "price_per_minute": float(row.get("price_per_minute") or 0),
        "minimum_fare": float(row.get("minimum_fare") or 0),
        "currency": row.get("currency") or "KES",
    }


def _fare_breakdown(pricing: dict, distance_meters, duration_seconds) -> dict:
    km = max(float(distance_meters or 0), 0) / 1000.0
    minutes = max(float(duration_seconds or 0), 0) / 60.0
    base = float(pricing.get("base_fare") or 0)
    per_km = round(km * float(pricing.get("price_per_km") or 0), 2)
    per_min = round(minutes * float(pricing.get("price_per_minute") or 0), 2)
    total = round(base + per_km + per_min, 2)
    minimum = float(pricing.get("minimum_fare") or 0)
    applied = max(total, minimum) if minimum else total
    return {
        "base_fare": round(base, 2),
        "distance_fare": per_km,
        "time_fare": per_min,
        "subtotal": total,
        "minimum_fare": round(minimum, 2),
        "minimum_applied": bool(minimum and total < minimum),
        "total": round(applied, 2),
        "currency": pricing.get("currency") or "KES",
    }


def _load_ride_for(db, ride_id: str) -> dict:
    """Fetch a ride, enforcing that the caller is its rider (or its driver)."""
    cur = db.cursor(cursor_factory=RealDictCursor)
    cur.execute(
        """SELECT r.*, ru.full_name AS rider_name, ru.phone AS rider_phone,
                  du.full_name AS driver_name, du.phone AS driver_phone,
                  d.rating AS driver_rating, d.base_fare, d.price_per_km,
                  d.price_per_minute, d.minimum_fare,
                  d.currency AS driver_currency,
                  d.latitude AS driver_latitude,
                  d.longitude AS driver_longitude,
                  d.last_seen AS driver_last_seen,
                  v.make AS vehicle_make, v.model AS vehicle_model,
                  v.plate_number AS vehicle_plate, v.color AS vehicle_color,
                  v.vehicle_class AS vehicle_class_resolved
           FROM rides r
           LEFT JOIN users ru ON ru.id = r.rider_id
           LEFT JOIN drivers d ON d.id = r.driver_id
           LEFT JOIN users du ON du.id = d.user_id
           LEFT JOIN LATERAL (
               SELECT * FROM vehicles vv
               WHERE vv.driver_id = d.id
               ORDER BY vv.is_default DESC, vv.created_at ASC
               LIMIT 1
           ) v ON TRUE
           WHERE r.id = %s""",
        (ride_id,),
    )
    ride = cur.fetchone()

    if ride is None:
        cur.close()
        raise HTTPException(status_code=404, detail="Ride not found")
    cur.close()
    return ride


def _serialize_ride(ride: dict) -> dict:
    pricing = _pricing_row(ride)
    breakdown = _fare_breakdown(
        pricing, ride["distance_meters"], ride["duration_seconds"]
    )
    fare = ride["fare_final"] if ride["fare_final"] is not None else ride["fare_estimate"]

    driver = None
    if ride["driver_id"]:
        driver = {
            "id": ride["driver_id"],
            "full_name": ride["driver_name"] or "",
            "phone": ride["driver_phone"] or "",
            "rating": float(ride["driver_rating"] or 0),
            "latitude": ride["driver_latitude"],
            "longitude": ride["driver_longitude"],
            "last_seen": (
                ride["driver_last_seen"].isoformat()
                if ride["driver_last_seen"]
                else None
            ),
            "vehicle": {
                "make": ride["vehicle_make"] or "",
                "model": ride["vehicle_model"] or "",
                "plate_number": ride["vehicle_plate"] or "",
                "color": ride["vehicle_color"],
                "vehicle_class": ride["vehicle_class_resolved"] or "standard",
            },
        }

    return {
        "id": ride["id"],
        "state": ride["state"],
        "rider_id": ride["rider_id"],
        "driver_id": ride["driver_id"],
        "driver": driver,
        "rider": {
            "id": ride["rider_id"],
            "full_name": ride["rider_name"] or "",
            "phone": ride["rider_phone"] or "",
        },
        "vehicle_class": ride["vehicle_class"] or "standard",
        "fare_estimate": ride["fare_estimate"],
        "fare_final": ride["fare_final"],
        "quoted_fare": fare,
        "fare_breakdown": breakdown,
        "pricing": pricing,
        "currency": ride["currency"] or pricing["currency"],
        "distance_meters": ride["distance_meters"],
        "duration_seconds": ride["duration_seconds"],
        "pickup": {
            "lat": ride["pickup_lat"],
            "lng": ride["pickup_lng"],
            "address": ride["pickup_place"] or "",
            "place_name": ride["pickup_place"] or "",
        },
        "dropoff": {
            "lat": ride["dropoff_lat"],
            "lng": ride["dropoff_lng"],
            "address": ride["dropoff_place"] or "",
            "place_name": ride["dropoff_place"] or "",
        },
        "otp": ride["otp"],
        "requested_at": ride["requested_at"].isoformat() if ride["requested_at"] else None,
        "accepted_at": ride["accepted_at"].isoformat() if ride["accepted_at"] else None,
        "arrived_at": ride["arrived_at"].isoformat() if ride["arrived_at"] else None,
        "started_at": ride["started_at"].isoformat() if ride["started_at"] else None,
        "completed_at": ride["completed_at"].isoformat() if ride["completed_at"] else None,
        "cancelled_at": ride["cancelled_at"].isoformat() if ride["cancelled_at"] else None,
        "cancellation_reason": ride["cancellation_reason"],
    }


def _guard_rider_idle(db, rider_id: str) -> None:
    """A rider may only have one live ride at a time."""
    cur = db.cursor(cursor_factory=RealDictCursor)
    cur.execute(
        "SELECT id FROM rides WHERE rider_id = %s AND state = ANY(%s) LIMIT 1",
        (rider_id, list(ACTIVE_RIDE_STATES)),
    )
    row = cur.fetchone()
    cur.close()
    if row is not None:
        raise HTTPException(
            status_code=409,
            detail="You already have a ride in progress",
        )


@app.post("/rides", status_code=status.HTTP_201_CREATED)
def create_ride(
    req: RideRequestIn,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    """Create a ride request assigned to a chosen online driver."""
    pickup = req.pickup or {}
    dropoff = req.dropoff or {}
    try:
        pickup_lat = float(pickup.get("lat"))
        pickup_lng = float(pickup.get("lng"))
        dropoff_lat = float(dropoff.get("lat"))
        dropoff_lng = float(dropoff.get("lng"))
    except (TypeError, ValueError):
        raise HTTPException(status_code=422, detail="pickup and dropoff need lat/lng")

    if not req.driver_id:
        raise HTTPException(status_code=422, detail="driver_id is required")

    cur = db.cursor(cursor_factory=RealDictCursor)
    cur.execute(
        "SELECT * FROM drivers WHERE id = %s FOR UPDATE", (req.driver_id,)
    )
    driver = cur.fetchone()
    if driver is None:
        cur.close()
        raise HTTPException(status_code=404, detail="Driver not found")

    if not driver["is_online"]:
        cur.close()
        raise HTTPException(status_code=409, detail="That driver is no longer online")

    cur.execute(
        """SELECT id FROM rides
           WHERE driver_id = %s AND state = ANY(%s)
           LIMIT 1""",
        (driver["id"], list(ACTIVE_RIDE_STATES)),
    )
    busy = cur.fetchone()
    if busy is not None:
        cur.close()
        raise HTTPException(
            status_code=409, detail="That driver is busy with another rider"
        )

    _guard_rider_idle(db, current_user["id"])

    pricing = _pricing_row(driver)
    distance = float(req.distance_meters or 0)
    duration = float(req.duration_seconds or 0)
    fare = _fare_breakdown(pricing, distance, duration)["total"]

    now = datetime.datetime.utcnow()
    ride_id = str(uuid.uuid4())
    cur.execute(
        """INSERT INTO rides (
               id, rider_id, driver_id, vehicle_class, fare_estimate,
               fare_final, currency, distance_meters, duration_seconds,
               pickup_lat, pickup_lng, pickup_place,
               dropoff_lat, dropoff_lng, dropoff_place,
               state, otp, requested_at, created_at, updated_at
           ) VALUES (
               %s, %s, %s, %s, %s,
               %s, %s, %s, %s,
               %s, %s, %s,
               %s, %s, %s,
               'requested', %s, %s, %s, %s
           )""",
        (
            ride_id,
            current_user["id"],
            driver["id"],
            req.vehicle_class or "standard",
            fare,
            fare,
            req.currency or pricing["currency"],
            distance,
            duration,
            pickup_lat,
            pickup_lng,
            (pickup.get("place_name") or pickup.get("address") or "")[:255],
            dropoff_lat,
            dropoff_lng,
            (dropoff.get("place_name") or dropoff.get("address") or "")[:255],
            _new_otp(),
            now,
            now,
            now,
        ),
    )
    cur.close()

    return _serialize_ride(_load_ride_for(db, ride_id))


@app.get("/rides/active")
def get_active_ride(
    current_user: dict = Depends(get_current_user),
    db=Depends(get_optional_db),
):
    """The caller's unfinished ride, for either role.

    Signing out mid-trip only clears the local session, so the ride row stays.
    On the next sign-in this is what puts the rider or the driver straight back
    on the map. Returns `null` when there is nothing in progress.
    """
    if db is None:
        return {"ride": None}

    cur = db.cursor(cursor_factory=RealDictCursor)
    cur.execute(
        "SELECT id FROM drivers WHERE user_id = %s", (current_user["id"],)
    )
    driver_row = cur.fetchone()

    if driver_row is not None:
        # A driver has at most one live ride: an offer they have not answered
        # is a different thing entirely, so it does not resume here.
        cur.execute(
            """SELECT id FROM rides
               WHERE driver_id = %s AND state = ANY(%s)
               ORDER BY created_at DESC
               LIMIT 1""",
            (
                driver_row["id"],
                list(
                    (
                        "accepted",
                        "driver_arriving",
                        "driver_arrived",
                        "ongoing",
                    )
                ),
            ),
        )
    else:
        cur.execute(
            """SELECT id FROM rides
               WHERE rider_id = %s AND state = ANY(%s)
               ORDER BY created_at DESC
               LIMIT 1""",
            (
                current_user["id"],
                list(
                    (
                        "requested",
                        "matching",
                        "accepted",
                        "driver_arriving",
                        "driver_arrived",
                        "ongoing",
                    )
                ),
            ),
        )

    row = cur.fetchone()
    cur.close()

    if row is None:
        return {"ride": None}

    return {
        "ride": _serialize_ride(_load_ride_for(db, row["id"])),
        "role": "driver" if driver_row is not None else "rider",
    }


@app.get("/rides/{ride_id}")
def get_ride(
    ride_id: str,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    """Live status of a ride, for the rider or the assigned driver."""
    ride = _load_ride_for(db, ride_id)
    _assert_ride_party(db, ride, current_user)
    return _serialize_ride(ride)


def _assert_ride_party(db, ride: dict, current_user: dict) -> None:
    if ride["rider_id"] == current_user["id"]:
        return
    cur = db.cursor(cursor_factory=RealDictCursor)
    cur.execute(
        "SELECT id FROM drivers WHERE user_id = %s", (current_user["id"],)
    )
    row = cur.fetchone()
    cur.close()
    if row is None or row["id"] != ride["driver_id"]:
        raise HTTPException(status_code=403, detail="Not your ride")


@app.get("/drivers/me/offers")
def get_driver_offers(
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    """Ride requests waiting on the signed-in driver.

    Offers older than `OFFER_TTL_SECONDS` are expired here rather than by a
    background job, so a driver who left the app open does not come back to a
    stale request.
    """
    driver = _require_driver(current_user, db)
    cur = db.cursor(cursor_factory=RealDictCursor)
    cur.execute(
        """UPDATE rides
           SET state = 'expired',
               cancelled_at = NOW() AT TIME ZONE 'UTC',
               cancellation_reason = 'Offer expired',
               updated_at = NOW() AT TIME ZONE 'UTC'
           WHERE driver_id = %s
             AND state = ANY(%s)
             AND requested_at < (NOW() AT TIME ZONE 'UTC') - (%s * INTERVAL '1 second')
           RETURNING id""",
        (driver["id"], list(OFFER_STATES), float(OFFER_TTL_SECONDS)),
    )
    expired = [r["id"] for r in cur.fetchall()]

    cur.execute(
        """SELECT r.id, r.state, r.vehicle_class, r.distance_meters,
                  r.duration_seconds, r.pickup_place, r.dropoff_place,
                  r.requested_at, ru.full_name AS rider_name
           FROM rides r
           LEFT JOIN users ru ON ru.id = r.rider_id
           WHERE r.driver_id = %s AND r.state = ANY(%s)
           ORDER BY r.requested_at ASC""",
        (driver["id"], list(OFFER_STATES)),
    )
    rows = cur.fetchall()
    cur.close()

    offers = []
    for r in rows:
        offers.append({
            "id": r["id"],
            "state": r["state"],
            "vehicle_class": r["vehicle_class"] or "standard",
            "distance_meters": r["distance_meters"] or 0,
            "duration_seconds": r["duration_seconds"] or 0,
            "rider_name": r["rider_name"] or "Rider",
            "pickup_place": r["pickup_place"] or "",
            "dropoff_place": r["dropoff_place"] or "",
            "requested_at": r["requested_at"].isoformat() if r["requested_at"] else None,
            "expires_in_seconds": OFFER_TTL_SECONDS,
        })

    return {
        "offers": offers,
        "count": len(offers),
        "expired": expired,
    }


@app.get("/rides/{ride_id}/rider-location")
def get_rider_location(
    ride_id: str,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_optional_db),
):
    """Where the rider is right now, for the driver on their way to pickup.

    Riders push to `user_locations` every couple of seconds. The driver polls
    this so the rider's pin on their map moves in real time instead of sitting
    on the originally-booked pickup point.
    """
    if db is None:
        raise HTTPException(status_code=503, detail="Database unavailable")

    cur = db.cursor(cursor_factory=RealDictCursor)
    cur.execute(
        """SELECT id, rider_id, driver_id, pickup_lat, pickup_lng, state
           FROM rides WHERE id = %s""",
        (ride_id,),
    )
    ride = cur.fetchone()
    if ride is None:
        cur.close()
        raise HTTPException(status_code=404, detail="Ride not found")

    # The caller must be this ride's rider or its driver.
    if current_user["id"] != ride["rider_id"]:
        cur.execute(
            "SELECT id FROM drivers WHERE user_id = %s", (current_user["id"],)
        )
        driver_row = cur.fetchone()
        if driver_row is None or driver_row["id"] != ride["driver_id"]:
            cur.close()
            raise HTTPException(status_code=403, detail="Not your ride")

    # The most recent fix wins; anything older than 90s is treated as stale so
    # the driver is not shown a pin that has stopped updating.
    cur.execute(
        """SELECT lat, lng, accuracy, updated_at
           FROM user_locations
           WHERE user_id = %s
           ORDER BY updated_at DESC
           LIMIT 1""",
        (ride["rider_id"],),
    )
    latest = cur.fetchone()
    cur.close()

    now = datetime.datetime.utcnow()
    fresh = None
    if latest is not None and latest["updated_at"] is not None:
        age = (now - latest["updated_at"]).total_seconds()
        if age <= 90:
            fresh = {
                "lat": latest["lat"],
                "lng": latest["lng"],
                "accuracy": latest["accuracy"],
                "age_seconds": round(age, 1),
            }

    return {
        "rider_id": ride["rider_id"],
        "state": ride["state"],
        "live": fresh,
        # The booked pickup point, used until the rider's first fix lands and
        # as the destination of the leg to the customer.
        "pickup": {
            "lat": ride["pickup_lat"],
            "lng": ride["pickup_lng"],
        },
    }


@app.post("/rides/{ride_id}/accept")
def accept_ride(
    ride_id: str,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    driver = _require_driver(current_user, db)
    cur = db.cursor(cursor_factory=RealDictCursor)
    cur.execute(
        "SELECT id, state, driver_id FROM rides WHERE id = %s FOR UPDATE",
        (ride_id,),
    )
    ride = cur.fetchone()
    if ride is None:
        cur.close()
        raise HTTPException(status_code=404, detail="Ride not found")
    if ride["driver_id"] != driver["id"]:
        cur.close()
        raise HTTPException(status_code=403, detail="Ride is not assigned to you")
    if ride["state"] not in OFFER_STATES:
        cur.close()
        raise HTTPException(
            status_code=409, detail=f"Ride is already {ride['state']}"
        )

    cur.execute(
        """UPDATE rides
           SET state = 'accepted', accepted_at = NOW() AT TIME ZONE 'UTC',
               updated_at = NOW() AT TIME ZONE 'UTC'
           WHERE id = %s""",
        (ride_id,),
    )
    cur.close()
    return _serialize_ride(_load_ride_for(db, ride_id))


@app.post("/rides/{ride_id}/decline")
def decline_ride(
    ride_id: str,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    driver = _require_driver(current_user, db)
    cur = db.cursor(cursor_factory=RealDictCursor)
    cur.execute(
        "SELECT id, state, driver_id FROM rides WHERE id = %s FOR UPDATE",
        (ride_id,),
    )
    ride = cur.fetchone()
    if ride is None:
        cur.close()
        raise HTTPException(status_code=404, detail="Ride not found")
    if ride["driver_id"] != driver["id"]:
        cur.close()
        raise HTTPException(status_code=403, detail="Ride is not assigned to you")
    if ride["state"] not in OFFER_STATES:
        cur.close()
        raise HTTPException(
            status_code=409, detail=f"Ride is already {ride['state']}"
        )

    cur.execute(
        """UPDATE rides
           SET state = 'expired',
               cancelled_at = NOW() AT TIME ZONE 'UTC',
               cancellation_reason = 'Driver declined the request',
               updated_at = NOW() AT TIME ZONE 'UTC'
           WHERE id = %s""",
        (ride_id,),
    )
    cur.close()
    return _serialize_ride(_load_ride_for(db, ride_id))


@app.post("/rides/{ride_id}/state")
def advance_ride_state(
    ride_id: str,
    req: RideStateIn,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    """Progress an accepted ride: arriving -> arrived -> ongoing -> completed."""
    allowed_next = {
        "requested": ("accepted", "cancelled"),
        "matching": ("accepted", "cancelled"),
        "accepted": ("driver_arriving", "driver_arrived", "cancelled"),
        "driver_arriving": ("driver_arrived", "ongoing", "cancelled"),
        "driver_arrived": ("ongoing", "cancelled"),
        "ongoing": ("completed", "cancelled"),
    }
    timestamp_column = {
        "driver_arriving": "arrived_at",
        "driver_arrived": "arrived_at",
        "ongoing": "started_at",
        "completed": "completed_at",
        "cancelled": "cancelled_at",
    }

    if req.state not in timestamp_column:
        raise HTTPException(status_code=422, detail=f"Unsupported state {req.state}")

    ride = _load_ride_for(db, ride_id)
    _assert_ride_party(db, ride, current_user)

    # A rider may only walk away from a ride. Driving it forward — arriving,
    # starting, completing — is the driver's call alone.
    if ride["rider_id"] == current_user["id"] and req.state != "cancelled":
        raise HTTPException(
            status_code=403, detail="Only the driver can update this state"
        )

    current = ride["state"]
    if req.state not in allowed_next.get(current, ()):
        raise HTTPException(
            status_code=409, detail=f"Cannot go from {current} to {req.state}"
        )

    column = timestamp_column[req.state]
    sets = ["state = %s", "updated_at = NOW() AT TIME ZONE 'UTC'", f"{column} = NOW() AT TIME ZONE 'UTC'"]
    params: list = [req.state]

    if req.state == "cancelled":
        sets.append("cancellation_reason = %s")
        params.append(req.reason or "Cancelled")
    if req.state == "completed":
        sets.append("fare_final = COALESCE(fare_final, fare_estimate)")

    cur = db.cursor(cursor_factory=RealDictCursor)
    cur.execute(
        f"UPDATE rides SET {', '.join(sets)} WHERE id = %s RETURNING id",
        (*params, ride_id),
    )
    updated = cur.fetchone()
    cur.close()
    if updated is None:
        raise HTTPException(status_code=404, detail="Ride not found")

    if req.state == "completed":
        cur = db.cursor(cursor_factory=RealDictCursor)
        cur.execute(
            """UPDATE drivers
               SET total_trips = COALESCE(total_trips, 0) + 1,
                   updated_at = NOW() AT TIME ZONE 'UTC'
               WHERE id = %s""",
            (ride["driver_id"],),
        )
        cur.close()

    return _serialize_ride(_load_ride_for(db, ride_id))


@app.get("/rides/{ride_id}/rating")
def get_ride_rating(
    ride_id: str,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    """The rating left on a ride, or `null` when the rider has not rated yet.

    Lets the app show the prompt exactly once instead of every time the rider
    opens the app after finishing a trip.
    """
    ride = _load_ride_for(db, ride_id)
    _assert_ride_party(db, ride, current_user)

    cur = db.cursor(cursor_factory=RealDictCursor)
    cur.execute(
        """SELECT id, stars, reason, created_at
           FROM ratings
           WHERE ride_id = %s""",
        (ride_id,),
    )
    row = cur.fetchone()
    cur.close()

    if row is None:
        return {"ride_id": ride_id, "rating": None}

    return {
        "ride_id": ride_id,
        "rating": {
            "id": row["id"],
            "stars": row["stars"],
            "reason": row["reason"],
            "created_at": row["created_at"].isoformat(),
        },
    }


class RatingIn(BaseModel):
    stars: int
    reason: Optional[str] = None


@app.post("/rides/{ride_id}/rating", status_code=status.HTTP_201_CREATED)
def rate_ride(
    ride_id: str,
    req: RatingIn,
    current_user: dict = Depends(get_current_user),
    db=Depends(get_db),
):
    """A rider rates the driver once the trip is finished.

    One rating per ride. Re-rating the same ride replaces the old score rather
    than failing, so a rider who dismisses the prompt and gets it again can
    change their mind. The driver's headline number is a running average of
    every rating they have received.
    """
    if req.stars < 1 or req.stars > 5:
        raise HTTPException(status_code=422, detail="Stars must be between 1 and 5")

    ride = _load_ride_for(db, ride_id)
    _assert_ride_party(db, ride, current_user)

    # Ratings are the rider's to give, and only for a trip that actually ran.
    if ride["rider_id"] != current_user["id"]:
        raise HTTPException(
            status_code=403, detail="Only the rider can rate this ride"
        )
    if ride["state"] != "completed":
        raise HTTPException(
            status_code=409, detail="You can only rate a completed ride"
        )
    if ride["driver_id"] is None:
        raise HTTPException(
            status_code=409, detail="This ride had no driver to rate"
        )

    reason = (req.reason or "").strip() or None

    cur = db.cursor(cursor_factory=RealDictCursor)
    cur.execute(
        """INSERT INTO ratings
               (id, ride_id, rider_id, driver_id, stars, reason, created_at)
           VALUES (%s, %s, %s, %s, %s, %s, NOW() AT TIME ZONE 'UTC')
           ON CONFLICT (ride_id) DO UPDATE
               SET stars = EXCLUDED.stars,
                   reason = EXCLUDED.reason,
                   created_at = EXCLUDED.created_at
           RETURNING id, stars, reason, created_at""",
        (
            str(uuid.uuid4()),
            ride_id,
            current_user["id"],
            ride["driver_id"],
            req.stars,
            reason,
        ),
    )
    saved = cur.fetchone()

    # Recompute the headline from the ratings themselves rather than nudging
    # the old value, so a changed rating can never drift it.
    cur.execute(
        """UPDATE drivers d
           SET rating = COALESCE((
                   SELECT ROUND(AVG(stars)::numeric, 2)::float
                   FROM ratings
                   WHERE driver_id = d.id
               ), d.rating),
               updated_at = NOW() AT TIME ZONE 'UTC'
           WHERE d.id = %s""",
        (ride["driver_id"],),
    )
    cur.close()

    return {
        "id": saved["id"],
        "ride_id": ride_id,
        "driver_id": ride["driver_id"],
        "stars": saved["stars"],
        "reason": saved["reason"],
        "created_at": saved["created_at"].isoformat(),
    }