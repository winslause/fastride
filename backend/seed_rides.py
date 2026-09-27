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

# Use a fixed test user ID or find an existing rider user
RIDER_ID = "7a334937-2345-43ad-8d99-4006a7e3fa07"  # real user from DB

SAMPLE_RIDES = [
    {
        "state": "completed",
        "fare_estimate": 250,
        "fare_final": 280,
        "distance_meters": 4500,
        "duration_seconds": 900,
        "pickup_place": "Karen Shopping Centre, Nairobi",
        "dropoff_place": "Westlands, Nairobi",
        "vehicle_class": "standard",
        "driver_name": "Samuel Mwangi",
        "driver_rating": 4.9,
        "days_ago": 2,
        "minutes_dur": 15,
    },
    {
        "state": "completed",
        "fare_estimate": 150,
        "fare_final": 150,
        "distance_meters": 3200,
        "duration_seconds": 620,
        "pickup_place": "Nairobi CBD, Kenyatta Avenue",
        "dropoff_place": "Kilimani, Nairobi",
        "vehicle_class": "moto",
        "driver_name": "David Ochieng",
        "driver_rating": 4.7,
        "days_ago": 5,
        "minutes_dur": 10,
    },
    {
        "state": "completed",
        "fare_estimate": 400,
        "fare_final": 420,
        "distance_meters": 12000,
        "duration_seconds": 1800,
        "pickup_place": "Westlands, Nairobi",
        "dropoff_place": " JK Airport, Nairobi",
        "vehicle_class": "xl",
        "driver_name": "Grace Wanjiru",
        "driver_rating": 4.6,
        "days_ago": 8,
        "minutes_dur": 30,
    },
    {
        "state": "cancelled",
        "fare_estimate": 350,
        "fare_final": None,
        "distance_meters": None,
        "duration_seconds": None,
        "pickup_place": "Karen Shopping Centre, Nairobi",
        "dropoff_place": "Kilimani, Nairobi",
        "vehicle_class": "premium",
        "driver_name": None,
        "driver_rating": None,
        "days_ago": 1,
        "minutes_dur": None,
        "cancellation_reason": "Driver no-show",
    },
    {
        "state": "completed",
        "fare_estimate": 600,
        "fare_final": 580,
        "distance_meters": 25000,
        "duration_seconds": 2400,
        "pickup_place": "Nairobi CBD, Kenyatta Avenue",
        "dropoff_place": "Naivasha, Kenya",
        "vehicle_class": "premium",
        "driver_name": "Kevin Rotich",
        "driver_rating": 5.0,
        "days_ago": 12,
        "minutes_dur": 40,
    },
    {
        "state": "cancelled",
        "fare_estimate": 200,
        "fare_final": None,
        "distance_meters": None,
        "duration_seconds": None,
        "pickup_place": "Kilimani, Nairobi",
        "dropoff_place": "Westlands, Nairobi",
        "vehicle_class": "standard",
        "driver_name": None,
        "driver_rating": None,
        "days_ago": 3,
        "minutes_dur": None,
        "cancellation_reason": "Changed my mind",
    },
]


def main():
    conn = psycopg2.connect(**DB_CONFIG)
    conn.autocommit = True
    cur = conn.cursor()

    now = datetime.datetime.now()

    for ride in SAMPLE_RIDES:
        ride_id = str(uuid.uuid4())
        requested_at = now - datetime.timedelta(days=ride["days_ago"])

        cancelled_at = None
        completed_at = None
        if ride["state"] == "cancelled":
            cancelled_at = requested_at + datetime.timedelta(minutes=2)
        elif ride["state"] == "completed":
            travel_min = ride["minutes_dur"] or 10
            completed_at = requested_at + datetime.timedelta(minutes=travel_min + 3)

        cur.execute(
            """INSERT INTO rides
               (id, rider_id, state, fare_estimate, fare_final, currency,
                distance_meters, duration_seconds, pickup_place, dropoff_place,
                vehicle_class, otp, requested_at, completed_at, cancelled_at,
                cancellation_reason, created_at, updated_at)
               VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
               ON CONFLICT (id) DO NOTHING""",
            (
                ride_id,
                RIDER_ID,
                ride["state"],
                ride["fare_estimate"],
                ride["fare_final"],
                "KES",
                ride["distance_meters"],
                ride["duration_seconds"],
                ride["pickup_place"],
                ride["dropoff_place"],
                ride["vehicle_class"],
                None,
                requested_at,
                completed_at,
                cancelled_at,
                ride.get("cancellation_reason"),
                requested_at,
                now,
            ),
        )

    cur.close()
    conn.close()
    print(f"Seeded {len(SAMPLE_RIDES)} sample rides for rider {RIDER_ID}")


if __name__ == "__main__":
    main()
