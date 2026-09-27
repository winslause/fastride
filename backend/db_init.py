import psycopg2

DB_CONFIG = {
    "host": "127.0.0.1",
    "port": 5432,
    "user": "postgres",
    "password": "Shioso2023",
    "dbname": "fastride",
}


def main():
    conn = psycopg2.connect(**DB_CONFIG)
    conn.autocommit = True
    cur = conn.cursor()

    cur.execute("""
        CREATE TABLE IF NOT EXISTS users (
            id VARCHAR(36) PRIMARY KEY,
            full_name VARCHAR(255) NOT NULL,
            phone VARCHAR(50) NOT NULL,
            email VARCHAR(255) UNIQUE NOT NULL,
            password_hash VARCHAR(255) NOT NULL,
            role VARCHAR(20) NOT NULL DEFAULT 'rider',
            is_verified BOOLEAN DEFAULT FALSE,
            created_at TIMESTAMP NOT NULL,
            updated_at TIMESTAMP NOT NULL
        )
    """)

    cur.execute("""
        CREATE TABLE IF NOT EXISTS drivers (
            id VARCHAR(36) PRIMARY KEY,
            user_id VARCHAR(36) NOT NULL REFERENCES users(id),
            rating FLOAT DEFAULT 5.0,
            total_trips INTEGER DEFAULT 0,
            is_online BOOLEAN DEFAULT FALSE,
            is_verified BOOLEAN DEFAULT FALSE,
            latitude FLOAT,
            longitude FLOAT,
            last_seen TIMESTAMP,
            created_at TIMESTAMP NOT NULL,
            updated_at TIMESTAMP NOT NULL
        )
    """)

    cur.execute("ALTER TABLE drivers ADD COLUMN IF NOT EXISTS latitude FLOAT")
    cur.execute("ALTER TABLE drivers ADD COLUMN IF NOT EXISTS longitude FLOAT")
    cur.execute("ALTER TABLE drivers ADD COLUMN IF NOT EXISTS last_seen TIMESTAMP")

    cur.execute("""
        CREATE INDEX IF NOT EXISTS idx_drivers_location
        ON drivers(latitude, longitude)
    """)

    cur.execute("""
        CREATE TABLE IF NOT EXISTS vehicles (
            id VARCHAR(36) PRIMARY KEY,
            driver_id VARCHAR(36) NOT NULL REFERENCES drivers(id),
            make VARCHAR(100),
            model VARCHAR(100),
            plate_number VARCHAR(50),
            color VARCHAR(50),
            year INTEGER,
            vehicle_class VARCHAR(20) DEFAULT 'standard',
            seats INTEGER DEFAULT 4,
            photo_url TEXT
        )
    """)

    cur.execute("""
        CREATE TABLE IF NOT EXISTS places (
            id VARCHAR(36) PRIMARY KEY,
            user_id VARCHAR(36) REFERENCES users(id),
            query VARCHAR(255) NOT NULL,
            lat_bias FLOAT,
            lng_bias FLOAT,
            label VARCHAR(500) NOT NULL,
            primary_text VARCHAR(255) NOT NULL,
            secondary_text TEXT,
            lat FLOAT NOT NULL,
            lng FLOAT NOT NULL,
            source VARCHAR(50),
            created_at TIMESTAMP NOT NULL
        )
    """)

    cur.execute("""
        CREATE INDEX IF NOT EXISTS idx_places_cache
        ON places(query, lat_bias, lng_bias, created_at DESC)
    """)

    cur.execute("""
        CREATE INDEX IF NOT EXISTS idx_places_user
        ON places(user_id, created_at DESC)
    """)

    cur.execute("""
        CREATE TABLE IF NOT EXISTS user_locations (
            id VARCHAR(36) PRIMARY KEY,
            user_id VARCHAR(36) NOT NULL REFERENCES users(id),
            lat FLOAT NOT NULL,
            lng FLOAT NOT NULL,
            accuracy FLOAT,
            updated_at TIMESTAMP NOT NULL
        )
    """)

    cur.execute("""
        CREATE INDEX IF NOT EXISTS idx_user_locations_user
        ON user_locations(user_id, updated_at DESC)
    """)

    cur.execute("""
        CREATE INDEX IF NOT EXISTS idx_user_locations_recent
        ON user_locations(updated_at DESC)
    """)

    cur.execute("""
        CREATE TABLE IF NOT EXISTS rides (
            id VARCHAR(36) PRIMARY KEY,
            rider_id VARCHAR(36) NOT NULL REFERENCES users(id),
            driver_id VARCHAR(36) REFERENCES drivers(id),
            vehicle_class VARCHAR(20) DEFAULT 'standard',
            fare_estimate FLOAT,
            fare_final FLOAT,
            currency VARCHAR(10) DEFAULT 'KES',
            distance_meters FLOAT,
            duration_seconds FLOAT,
            pickup_lat FLOAT,
            pickup_lng FLOAT,
            pickup_place VARCHAR(255),
            dropoff_lat FLOAT,
            dropoff_lng FLOAT,
            dropoff_place VARCHAR(255),
            state VARCHAR(30) NOT NULL DEFAULT 'requested',
            otp VARCHAR(10),
            requested_at TIMESTAMP,
            accepted_at TIMESTAMP,
            arrived_at TIMESTAMP,
            started_at TIMESTAMP,
            completed_at TIMESTAMP,
            cancelled_at TIMESTAMP,
            cancellation_reason TEXT,
            created_at TIMESTAMP NOT NULL,
            updated_at TIMESTAMP NOT NULL
        )
    """)

    cur.execute("""
        CREATE INDEX IF NOT EXISTS idx_rides_rider
        ON rides(rider_id, created_at DESC)
    """)

    cur.execute("""
        CREATE INDEX IF NOT EXISTS idx_rides_driver
        ON rides(driver_id, created_at DESC)
    """)

    cur.execute("""
        CREATE INDEX IF NOT EXISTS idx_rides_state
        ON rides(state, created_at)
    """)

    cur.close()
    conn.close()
    print("Tables created successfully.")


if __name__ == "__main__":
    main()