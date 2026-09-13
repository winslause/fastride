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
            created_at TIMESTAMP NOT NULL,
            updated_at TIMESTAMP NOT NULL
        )
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

    cur.close()
    conn.close()
    print("Tables created successfully.")


if __name__ == "__main__":
    main()