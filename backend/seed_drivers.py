import uuid
import datetime
import psycopg2

DB_CONFIG = {
    "host": "127.0.0.1",
    "port": 5432,
    "user": "postgres",
    "password": "Shioso2023",
    "dbname": "fastride",
}

# Nairobi coordinates: lat -1.2921, lng 36.8219
NAIROBI_LAT = -1.2921
NAIROBI_LNG = 36.8219

DRIVERS = [
    {
        "full_name": "Samuel Mwangi",
        "phone": "+254712345678",
        "email": "samuel.mwangi@example.com",
        "password_hash": "$2b$12$placeholderplaceholderplaceholderplaceholder",
        "rating": 4.9,
        "total_trips": 1284,
        "vehicle_make": "Toyota",
        "vehicle_model": "Corolla",
        "plate_number": "KDA 123A",
        "vehicle_color": "Silver",
        "vehicle_class": "standard",
        "seats": 4,
    },
    {
        "full_name": "Aisha Mohamed",
        "phone": "+254723456789",
        "email": "aisha.mohamed@example.com",
        "password_hash": "$2b$12$placeholderplaceholderplaceholderplaceholder",
        "rating": 4.8,
        "total_trips": 956,
        "vehicle_make": "Honda",
        "vehicle_model": "Civic",
        "plate_number": "KDB 456B",
        "vehicle_color": "Black",
        "vehicle_class": "standard",
        "seats": 4,
    },
    {
        "full_name": "David Ochieng",
        "id": None,
        "phone": "+254734567890",
        "email": "david.ochieng@example.com",
        "password_hash": "$2b$12$placeholderplaceholderplaceholderplaceholder",
        "rating": 4.7,
        "total_trips": 723,
        "vehicle_make": "Suzuki",
        "vehicle_model": "Hayate",
        "plate_number": "KDC 789C",
        "vehicle_color": "Blue",
        "vehicle_class": "moto",
        "seats": 1,
    },
    {
        "full_name": "Grace Wanjiru",
        "phone": "+254745678901",
        "email": "grace.wanjiru@example.com",
        "password_hash": "$2b$12$placeholderplaceholderplaceholderplaceholder",
        "rating": 4.6,
        "total_trips": 512,
        "vehicle_make": "Toyota",
        "vehicle_model": "Proace",
        "plate_number": "KDE 345D",
        "vehicle_color": "White",
        "vehicle_class": "xl",
        "seats": 6,
    },
    {
        "full_name": "Kevin Rotich",
        "phone": "+254756789012",
        "email": "kevin.rotich@example.com",
        "password_hash": "$2b$12$placeholderplaceholderplaceholderplaceholder",
        "rating": 5.0,
        "total_trips": 340,
        "vehicle_make": "Mercedes-Benz",
        "vehicle_model": "E-Class",
        "plate_number": "KDF 678E",
        "vehicle_color": "Black",
        "vehicle_class": "premium",
        "seats": 4,
    },
]

# Offsets from Nairobi center in degrees (~1 km per 0.009 degrees)
import random

random.seed(42)
LOCATIONS = [
    (0.005, 0.003),
    (-0.004, 0.006),
    (0.002, -0.005),
    (-0.003, -0.002),
    (0.008, 0.001),
]


def main():
    conn = psycopg2.connect(**DB_CONFIG)
    conn.autocommit = True
    cur = conn.cursor()

    now = datetime.datetime.now()  # Use local time matching DB timezone

    for i, d in enumerate(DRIVERS):
        user_id = str(uuid.uuid4())
        driver_id = str(uuid.uuid4())
        vehicle_id = str(uuid.uuid4())

        lat_offset, lng_offset = LOCATIONS[i]
        driver_lat = NAIROBI_LAT + lat_offset
        driver_lng = NAIROBI_LNG + lng_offset

        # Insert user (skip if email already exists)
        cur.execute(
            """INSERT INTO users (id, full_name, phone, email, password_hash, role, is_verified, created_at, updated_at)
               VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s)
               ON CONFLICT (email) DO NOTHING""",
            (
                user_id,
                d["full_name"],
                d["phone"],
                d["email"],
                d["password_hash"],
                "driver",
                True,
                now,
                now,
            ),
        )

        # Get the existing user_id if the insert was skipped
        cur.execute(
            "SELECT id FROM users WHERE email = %s",
            (d["email"],),
        )
        row = cur.fetchone()
        if row:
            user_id = row[0]

        # Insert driver (skip if user already has a driver record)
        cur.execute("SELECT id FROM drivers WHERE user_id = %s", (user_id,))
        existing_driver = cur.fetchone()
        if existing_driver is None:
            cur.execute(
                """INSERT INTO drivers (id, user_id, rating, total_trips, is_online, is_verified, latitude, longitude, last_seen, created_at, updated_at)
                   VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)""",
                (
                    driver_id,
                    user_id,
                    d["rating"],
                    d["total_trips"],
                    True,
                    True,
                    driver_lat,
                    driver_lng,
                    now,
                    now,
                    now,
                ),
            )
        else:
            # Update existing driver's online status and location
            driver_id = existing_driver[0]
            cur.execute(
                """UPDATE drivers SET is_online = TRUE, is_verified = TRUE,
                   latitude = %s, longitude = %s, last_seen = %s, updated_at = %s
                   WHERE id = %s""",
                (driver_lat, driver_lng, now, now, driver_id),
            )

        # Insert vehicle (skip if driver already has one)
        cur.execute("SELECT id FROM vehicles WHERE driver_id = %s", (driver_id,))
        if cur.fetchone() is None:
            cur.execute(
                """INSERT INTO vehicles (id, driver_id, make, model, plate_number, color, year, vehicle_class, seats, photo_url)
                   VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s)""",
                (
                    vehicle_id,
                    driver_id,
                    d["vehicle_make"],
                    d["vehicle_model"],
                    d["plate_number"],
                    d["vehicle_color"],
                    2020 + i,
                    d["vehicle_class"],
                    d["seats"],
                    None,
                ),
            )

    cur.close()
    conn.close()
    print(f"Seeded {len(DRIVERS)} drivers near Nairobi successfully.")


if __name__ == "__main__":
    main()
