BEGIN;
-- Таблица журнала
DROP TABLE IF EXISTS audit.function_calls CASCADE;

CREATE TABLE audit.function_calls (
    call_id       BIGSERIAL    PRIMARY KEY,
    call_time     TIMESTAMPTZ  NOT NULL DEFAULT clock_timestamp(),
    function_name TEXT         NOT NULL,
    caller_role   TEXT         NOT NULL DEFAULT session_user,  -- реальный вызывающий
    input_params  JSONB        NOT NULL DEFAULT '{}'::jsonb,
    success       BOOLEAN      NOT NULL,
    error_code    VARCHAR(5),                                  -- SQLSTATE (LMS01..LMS07)
    error_message TEXT,
    CHECK (success OR error_code IS NOT NULL)                  -- у неуспешного вызова всегда есть код ошибки
);

CREATE INDEX idx_function_calls_time ON audit.function_calls (call_time);
CREATE INDEX idx_function_calls_fn   ON audit.function_calls (function_name, success);

COMMENT ON TABLE  audit.function_calls               IS 'Журнал вызовов SECURITY DEFINER-функций';
COMMENT ON COLUMN audit.function_calls.caller_role   IS 'session_user — реальный вызывающий';
COMMENT ON COLUMN audit.function_calls.input_params  IS 'Входные параметры вызова в JSONB';
COMMENT ON COLUMN audit.function_calls.error_code    IS 'SQLSTATE ошибки; NULL для успешных вызовов';

-- Привилегии на журнал
REVOKE ALL ON TABLE audit.function_calls FROM PUBLIC;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE audit.function_calls FROM dml_admin, auditor, security_admin;
REVOKE ALL ON SEQUENCE audit.function_calls_call_id_seq FROM PUBLIC, dml_admin;

-- Чтение журнала — только ролям аудита
GRANT SELECT ON TABLE audit.function_calls TO auditor, security_admin;

-- Вспомогательная функция записи в журнал

CREATE OR REPLACE FUNCTION audit.log_function_call(
    p_function_name TEXT,
    p_input_params  JSONB,
    p_success       BOOLEAN,
    p_error_code    TEXT DEFAULT NULL,
    p_error_message TEXT DEFAULT NULL
)
RETURNS BIGINT
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_call_id BIGINT;
BEGIN
    INSERT INTO audit.function_calls (call_time, function_name, caller_role, input_params, success, error_code, error_message)
    VALUES (clock_timestamp(), p_function_name, session_user::text, 
            COALESCE(p_input_params, '{}'::jsonb), p_success, p_error_code, p_error_message)
    RETURNING call_id INTO v_call_id;

    RETURN v_call_id;
END;
$$;

COMMENT ON FUNCTION audit.log_function_call(TEXT, JSONB, BOOLEAN, TEXT, TEXT) IS
    'SECURITY DEFINER: запись строки в audit.function_calls. Вызывается только из других SECURITY DEFINER-функций';

REVOKE ALL ON FUNCTION audit.log_function_call(TEXT, JSONB, BOOLEAN, TEXT, TEXT) FROM PUBLIC;

COMMIT;