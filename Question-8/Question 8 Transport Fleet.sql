-- ============================================================
-- QUESTION 8 - TRANSPORT FLEET MAINTENANCE
-- POSTGRESQL / pgAdmin 4 VERSION
-- Service due when km_since_service >= 5000
-- ============================================================

-- ------------------------------------------------------------
-- (a) TABLES
-- ------------------------------------------------------------
DROP TABLE IF EXISTS service_alerts CASCADE;
DROP TABLE IF EXISTS trips CASCADE;
DROP TABLE IF EXISTS vehicles CASCADE;

CREATE TABLE vehicles (
    vehicle_id           SERIAL PRIMARY KEY,
    registration         VARCHAR(20)  NOT NULL UNIQUE,
    current_odometer     NUMERIC(12, 2) NOT NULL CHECK (current_odometer >= 0),
    last_service_odometer NUMERIC(12, 2) NOT NULL CHECK (last_service_odometer >= 0),
    CHECK (last_service_odometer <= current_odometer)
);

CREATE TABLE trips (
    trip_id        SERIAL PRIMARY KEY,
    vehicle_id     INT NOT NULL REFERENCES vehicles(vehicle_id),
    trip_on        DATE NOT NULL,
    start_odometer NUMERIC(12, 2) NOT NULL CHECK (start_odometer >= 0),
    end_odometer   NUMERIC(12, 2) NOT NULL CHECK (end_odometer >= 0)
);

CREATE TABLE service_alerts (
    vehicle_id       INT PRIMARY KEY REFERENCES vehicles(vehicle_id),
    km_since_service NUMERIC(12, 2) NOT NULL,
    flagged_on       DATE NOT NULL
);

-- Seed vehicles
-- V1: 2000 km since service - NOT due
-- V2: 3000 km since service - NOT due
-- V3: 4500 km since service - NOT due yet, becomes due after trips
INSERT INTO vehicles (registration, current_odometer, last_service_odometer) VALUES
    ('ABC 123', 12000, 10000),
    ('DEF 456',  8000,  5000),
    ('GHI 789',  4500,     0);

-- ------------------------------------------------------------
-- (b) FUNCTION - Is service due?
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_service_due(p_vehicle_id INT)
RETURNS BOOLEAN
LANGUAGE plpgsql
AS $$
DECLARE
    v_km NUMERIC;
BEGIN
    SELECT (current_odometer - last_service_odometer)
    INTO v_km
    FROM vehicles
    WHERE vehicle_id = p_vehicle_id;

    IF v_km IS NULL THEN
        RAISE EXCEPTION 'Unknown vehicle';
    END IF;

    RETURN v_km >= 5000;
END;
$$;

-- ------------------------------------------------------------
-- (c) PROCEDURE - Record a trip
-- ------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_record_trip(
    p_vehicle_id INT,
    p_trip_on    DATE,
    p_start      NUMERIC,
    p_end        NUMERIC
)
LANGUAGE plpgsql
AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM vehicles WHERE vehicle_id = p_vehicle_id) THEN
        RAISE EXCEPTION 'Unknown vehicle';
    END IF;

    IF p_end <= p_start THEN
        RAISE EXCEPTION 'End must be > start';
    END IF;

    INSERT INTO trips (vehicle_id, trip_on, start_odometer, end_odometer)
    VALUES (p_vehicle_id, p_trip_on, p_start, p_end);
END;
$$;

-- ------------------------------------------------------------
-- (d) TRIGGER - BEFORE INSERT ON trips
--      1. Validate mileage
--      2. Start must equal current odometer (no gap / overlap)
--      3. Auto-update vehicles.current_odometer
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_trips_before_insert()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_current NUMERIC;
BEGIN
    SELECT current_odometer INTO v_current
    FROM vehicles
    WHERE vehicle_id = NEW.vehicle_id;

    IF v_current IS NULL THEN
        RAISE EXCEPTION 'Unknown vehicle';
    END IF;

    IF NEW.end_odometer <= NEW.start_odometer THEN
        RAISE EXCEPTION 'Invalid mileage';
    END IF;

    IF NEW.start_odometer <> v_current THEN
        RAISE EXCEPTION 'Start must equal current odometer';
    END IF;

    UPDATE vehicles
    SET current_odometer = NEW.end_odometer
    WHERE vehicle_id = NEW.vehicle_id;

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_trips_before_insert ON trips;
CREATE TRIGGER trg_trips_before_insert
BEFORE INSERT ON trips
FOR EACH ROW EXECUTE FUNCTION trg_trips_before_insert();

-- ------------------------------------------------------------
-- (a) SEED - 6 trips, AFTER trigger
-- ------------------------------------------------------------
CALL pr_record_trip(1, '2026-11-20', 12000, 12500);
CALL pr_record_trip(1, '2026-11-21', 12500, 13000);
CALL pr_record_trip(2, '2026-11-20',  8000,  8500);
CALL pr_record_trip(2, '2026-11-21',  8500,  9000);
CALL pr_record_trip(3, '2026-11-20',  4500,  4700);
CALL pr_record_trip(3, '2026-11-21',  4700,  5000);

-- Check results:
-- ABC 123: 13000 - 10000 = 3000  -> NOT due
-- DEF 456:  9000 -  5000 = 4000  -> NOT due
-- GHI 789:  5000 -     0 = 5000  -> DUE (boundary)

-- ------------------------------------------------------------
-- (e) VIEW - Vehicles due for service
-- ------------------------------------------------------------
CREATE OR REPLACE VIEW v_service_due AS
SELECT
    registration,
    (current_odometer - last_service_odometer) AS km_since_service
FROM vehicles
WHERE (current_odometer - last_service_odometer) >= 5000;

SELECT * FROM v_service_due;
SELECT fn_service_due(3) AS vehicle_3_due; -- should be true

-- ------------------------------------------------------------
-- (f) INDEX - Trips for one vehicle between two dates
-- ------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_trips_vehicle_date
    ON trips (vehicle_id, trip_on);

EXPLAIN
SELECT * FROM trips
WHERE vehicle_id = 1
  AND trip_on BETWEEN '2026-11-20' AND '2026-11-21';

-- ------------------------------------------------------------
-- (g) SCHEDULED JOB - Refresh service_alerts
-- ------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_refresh_service_alerts()
LANGUAGE plpgsql
AS $$
BEGIN
    -- Insert / update vehicles that ARE due
    INSERT INTO service_alerts (vehicle_id, km_since_service, flagged_on)
    SELECT
        vehicle_id,
        (current_odometer - last_service_odometer),
        CURRENT_DATE
    FROM vehicles
    WHERE (current_odometer - last_service_odometer) >= 5000
    ON CONFLICT (vehicle_id)
    DO UPDATE SET
        km_since_service = EXCLUDED.km_since_service,
        flagged_on       = EXCLUDED.flagged_on;

    -- Remove vehicles that are NO LONGER due (serviced)
    DELETE FROM service_alerts
    WHERE vehicle_id NOT IN (
        SELECT vehicle_id FROM vehicles
        WHERE (current_odometer - last_service_odometer) >= 5000
    );
END;
$$;

-- Test it
CALL pr_refresh_service_alerts();
SELECT * FROM service_alerts;

-- Real scheduled job in PostgreSQL - pg_cron, every Monday 06:00:
-- CREATE EXTENSION IF NOT EXISTS pg_cron;
-- SELECT cron.schedule('refresh-service-alerts', '0 6 * * 1',
--   $$CALL pr_refresh_service_alerts();$$);