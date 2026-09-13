import uuid
import datetime
import bcrypt
from typing import Optional

import psycopg2
from psycopg2.extras import RealDictCursor
from fastapi import FastAPI, Depends, HTTPException, status, Response
from fastapi.security import HTTPBearer, HTTPAuthorizationCredentials
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
from jose import JWTError, jwt
from datetime import timedelta

app = FastAPI(title="FastRide API")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

security = HTTPBearer()


@app.options("/{path:path}")
@app.options("")
def options_handler(path: Optional[str] = None):
    return Response(status_code=204)


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


def get_db():
    conn = psycopg2.connect(**DB_CONFIG)
    conn.autocommit = True
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