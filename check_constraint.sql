BEGIN;

ALTER TABLE app.exam_sessions DROP CONSTRAINT IF EXISTS chk_session_status_consistency;

-- ADD CONSTRAINT без NOT VALID проверяет и все уже существующие строки
ALTER TABLE app.exam_sessions
    ADD CONSTRAINT chk_session_status_consistency CHECK (
           (status = 'scheduled'   AND started_at IS NULL     AND finished_at IS NULL)
        OR (status = 'in_progress' AND started_at IS NOT NULL AND finished_at IS NULL)
        OR (status = 'completed'   AND started_at IS NOT NULL AND finished_at IS NOT NULL
                                   AND finished_at >= started_at)
        OR (status = 'cancelled'   AND (finished_at IS NULL
                                        OR (started_at IS NOT NULL AND finished_at >= started_at)))
    );

COMMENT ON CONSTRAINT chk_session_status_consistency ON app.exam_sessions IS
    'Согласованность статуса сессии и временных меток';

COMMIT;