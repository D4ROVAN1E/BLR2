-- Таблица с ограничением CHECK
DROP TABLE IF EXISTS app.test_sessions_check CASCADE;

CREATE TABLE app.test_sessions_check (
    session_id    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    exam_id       UUID NOT NULL,
    user_id       UUID NOT NULL,
    status        VARCHAR(30) NOT NULL DEFAULT 'scheduled',
    session_token VARCHAR(64) NOT NULL,
    started_at    TIMESTAMPTZ,
    finished_at   TIMESTAMPTZ,
    CONSTRAINT chk_session_status_and_dates CHECK (
        (status = 'scheduled'   AND started_at IS NULL     AND finished_at IS NULL)
     OR (status = 'in_progress' AND started_at IS NOT NULL AND finished_at IS NULL)
     OR (status = 'completed'   AND started_at IS NOT NULL AND finished_at IS NOT NULL 
                                AND finished_at >= started_at)
    )
);


-- Таблица без CHECK-ограничения
DROP TABLE IF EXISTS app.test_sessions_trigger CASCADE;

CREATE TABLE app.test_sessions_trigger (
    session_id    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    exam_id       UUID NOT NULL,
    user_id       UUID NOT NULL,
    status        VARCHAR(30) NOT NULL DEFAULT 'scheduled',
    session_token VARCHAR(64) NOT NULL,
    started_at    TIMESTAMPTZ,
    finished_at   TIMESTAMPTZ
);

-- Триггерная функция валидации
CREATE OR REPLACE FUNCTION app.fn_validate_session_trigger()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    -- Проверка запланированной сессии
    IF NEW.status = 'scheduled' THEN
        IF NEW.started_at IS NOT NULL OR NEW.finished_at IS NOT NULL THEN
            RAISE EXCEPTION 'Ошибка: запланированная сессия не может иметь меток времени'
            USING ERRCODE = 'check_violation';
        END IF;

    -- Проверка активной сессии
    ELSIF NEW.status = 'in_progress' THEN
        IF NEW.started_at IS NULL OR NEW.finished_at IS NOT NULL THEN
            RAISE EXCEPTION 'Ошибка: активная сессия обязана иметь started_at и не иметь finished_at'
            USING ERRCODE = 'check_violation';
        END IF;

    -- Проверка завершенной сессии
    ELSIF NEW.status = 'completed' THEN
        IF NEW.started_at IS NULL OR NEW.finished_at IS NULL OR NEW.finished_at < NEW.started_at THEN
            RAISE EXCEPTION 'Ошибка: завершенная сессия должна иметь started_at и finished_at (finished_at >= started_at)'
            USING ERRCODE = 'check_violation';
        END IF;
    END IF;

    RETURN NEW;
END;
$$;


-- Назначение BEFORE-триггера
CREATE TRIGGER trg_validate_session_rules
BEFORE INSERT OR UPDATE ON app.test_sessions_trigger
FOR EACH ROW
EXECUTE FUNCTION app.fn_validate_session_trigger();


TRUNCATE app.test_sessions_check;

EXPLAIN ANALYZE
INSERT INTO app.test_sessions_check (exam_id, user_id, status, session_token, started_at, finished_at)
SELECT 
    gen_random_uuid(),
    gen_random_uuid(),
    'completed',
    'chk_tok_' || g,
    now(),
    now() + interval '30 minutes'
FROM generate_series(1, 10000) AS g;


TRUNCATE app.test_sessions_trigger;

EXPLAIN ANALYZE
INSERT INTO app.test_sessions_trigger (exam_id, user_id, status, session_token, started_at, finished_at)
SELECT 
    gen_random_uuid(),
    gen_random_uuid(),
    'completed',
    'trg_tok_' || g,
    now(),
    now() + interval '30 minutes'
FROM generate_series(1, 10000) AS g;


-- CHECK:
INSERT INTO app.test_sessions_check (exam_id, user_id, status, session_token, started_at, finished_at)
VALUES (gen_random_uuid(), gen_random_uuid(), 'scheduled', 'ERR-01', now(), NULL);

-- ТРИГГЕР:
INSERT INTO app.test_sessions_trigger (exam_id, user_id, status, session_token, started_at, finished_at)
VALUES (gen_random_uuid(), gen_random_uuid(), 'scheduled', 'ERR-01', now(), NULL);


-- CHECK:
INSERT INTO app.test_sessions_check (exam_id, user_id, status, session_token, started_at, finished_at)
VALUES (gen_random_uuid(), gen_random_uuid(), 'in_progress', 'ERR-02', NULL, NULL);

-- ТРИГГЕР:
INSERT INTO app.test_sessions_trigger (exam_id, user_id, status, session_token, started_at, finished_at)
VALUES (gen_random_uuid(), gen_random_uuid(), 'in_progress', 'ERR-02', NULL, NULL);


-- CHECK:
INSERT INTO app.test_sessions_check (exam_id, user_id, status, session_token, started_at, finished_at)
VALUES (gen_random_uuid(), gen_random_uuid(), 'completed', 'ERR-03', now(), now() - interval '1 hour');

-- ТРИГГЕР:
INSERT INTO app.test_sessions_trigger (exam_id, user_id, status, session_token, started_at, finished_at)
VALUES (gen_random_uuid(), gen_random_uuid(), 'completed', 'ERR-03', now(), now() - interval '1 hour');