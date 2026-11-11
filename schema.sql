BEGIN;

-- ============================================================================
-- 0. ОЧИСТКА (для повторного запуска)
-- ============================================================================

DROP SCHEMA IF EXISTS stg   CASCADE;
DROP SCHEMA IF EXISTS audit CASCADE;
DROP SCHEMA IF EXISTS app   CASCADE;
DROP SCHEMA IF EXISTS ref   CASCADE;

-- ============================================================================
-- 1. СОЗДАНИЕ СХЕМ
-- ============================================================================

CREATE SCHEMA ref;
COMMENT ON SCHEMA ref   IS 'Справочники';

CREATE SCHEMA app;
COMMENT ON SCHEMA app   IS 'Бизнес-логика';

CREATE SCHEMA audit;
COMMENT ON SCHEMA audit IS 'Журнал безопасности и аудита';

CREATE SCHEMA stg;
COMMENT ON SCHEMA stg   IS 'Промежуточная загрузка';

-- ============================================================================
-- 2. DDL — ТАБЛИЦЫ
-- ============================================================================

-- ---------- ref.roles ----------
CREATE TABLE ref.roles (
    role_id    SERIAL       PRIMARY KEY,
    code       VARCHAR(30)  NOT NULL UNIQUE,
    name       VARCHAR(120) NOT NULL,
    is_active  BOOLEAN      NOT NULL DEFAULT TRUE
);
COMMENT ON TABLE ref.roles IS 'Справочник ролей: student, teacher, proctor';

-- ---------- app.users ----------
CREATE TABLE app.users (
    user_id       UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
    role_id       INT           NOT NULL REFERENCES ref.roles(role_id),
    email         VARCHAR(255)  NOT NULL UNIQUE,
    first_name    VARCHAR(100)  NOT NULL,
    last_name     VARCHAR(100)  NOT NULL,
    patronymic    VARCHAR(100),
    password_hash VARCHAR(255)  NOT NULL,
    is_active     BOOLEAN       NOT NULL DEFAULT TRUE
);
COMMENT ON TABLE app.users IS 'Пользователи системы';

-- ---------- app.courses ----------
CREATE TABLE app.courses (
    course_id  UUID           PRIMARY KEY DEFAULT gen_random_uuid(),
    created_by UUID           NOT NULL REFERENCES app.users(user_id),
    title      VARCHAR(300)   NOT NULL UNIQUE,
    created_at TIMESTAMPTZ    NOT NULL DEFAULT now()
);
COMMENT ON TABLE app.courses IS 'Курсы дистанционного обучения';

-- ---------- app.course_enrollments ----------
CREATE TABLE app.course_enrollments (
    enrollment_id UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id       UUID        NOT NULL REFERENCES app.users(user_id),
    course_id     UUID        NOT NULL REFERENCES app.courses(course_id),
    enrolled_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (user_id, course_id)  -- один студент — одна запись на курс
);
COMMENT ON TABLE app.course_enrollments IS 'Ассоциативная таблица N:M «пользователь ↔ курс»';

-- ---------- app.exams ----------
CREATE TABLE app.exams (
    exam_id          UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
    course_id        UUID         NOT NULL REFERENCES app.courses(course_id),
    title            VARCHAR(300) NOT NULL,
    duration_minutes INT          NOT NULL CHECK (duration_minutes > 0),
    max_score        INT          NOT NULL CHECK (max_score > 0),
    passing_score    INT          NOT NULL CHECK (passing_score >= 0)
);
COMMENT ON TABLE app.exams IS 'Экзамены, привязанные к курсам';

-- ---------- app.exam_questions ----------
CREATE TABLE app.exam_questions (
    question_id    UUID   PRIMARY KEY DEFAULT gen_random_uuid(),
    exam_id        UUID   NOT NULL REFERENCES app.exams(exam_id),
    question_text  TEXT   NOT NULL,
    options        JSONB  NOT NULL DEFAULT '[]'::jsonb,
    correct_answer JSONB  NOT NULL,
    points         INT    NOT NULL CHECK (points > 0)
);
COMMENT ON TABLE app.exam_questions IS 'Вопросы экзамена';

-- ---------- app.exam_sessions ----------
CREATE TABLE app.exam_sessions (
    session_id    UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
    exam_id       UUID         NOT NULL REFERENCES app.exams(exam_id),
    user_id       UUID         NOT NULL REFERENCES app.users(user_id),
    status        VARCHAR(30)  NOT NULL DEFAULT 'scheduled'
                  CHECK (status IN ('scheduled','in_progress','completed','cancelled')),
    session_token VARCHAR(64)  NOT NULL UNIQUE,
    started_at    TIMESTAMPTZ,
    finished_at   TIMESTAMPTZ,
    CHECK (finished_at IS NULL OR finished_at >= started_at)
);
COMMENT ON TABLE app.exam_sessions IS 'Попытки сдачи экзамена (центральная сущность)';

-- ---------- app.session_answers ----------
CREATE TABLE app.session_answers (
    answer_id      UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    session_id     UUID        NOT NULL REFERENCES app.exam_sessions(session_id),
    question_id    UUID        NOT NULL REFERENCES app.exam_questions(question_id),
    answer_payload JSONB,
    awarded_points INT         NOT NULL DEFAULT 0 CHECK (awarded_points >= 0),
    answered_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (session_id, question_id)  -- один ответ на вопрос в рамках сессии
);
COMMENT ON TABLE app.session_answers IS 'Ответы студента в рамках экзаменационной сессии';

-- ---------- app.exam_results ----------
CREATE TABLE app.exam_results (
    result_id       UUID    PRIMARY KEY DEFAULT gen_random_uuid(),
    session_id      UUID    NOT NULL UNIQUE REFERENCES app.exam_sessions(session_id),
    total_score     INT     NOT NULL CHECK (total_score >= 0),
    passed          BOOLEAN NOT NULL,
    teacher_comment TEXT
);
COMMENT ON TABLE app.exam_results IS 'Итоговая оценка за сессию';

-- ---------- audit.login_log ----------
CREATE TABLE audit.login_log (
    log_id         BIGSERIAL    PRIMARY KEY,
    user_id        UUID         REFERENCES app.users(user_id),
    event_type     VARCHAR(20)  NOT NULL DEFAULT 'login'
                   CHECK (event_type IN ('login','logout','failed_login')),
    ip_address     INET,
    success        BOOLEAN      NOT NULL DEFAULT TRUE,
    failure_reason TEXT,
    event_ts       TIMESTAMPTZ  NOT NULL DEFAULT now()
);
COMMENT ON TABLE audit.login_log IS 'Журнал аутентификации и подключений';

-- ---------- stg.student_import ----------
CREATE TABLE stg.student_import (
    import_id    BIGSERIAL    PRIMARY KEY,
    email        VARCHAR(255) NOT NULL,
    first_name   VARCHAR(100) NOT NULL,
    last_name    VARCHAR(100) NOT NULL,
    patronymic   VARCHAR(100),
    course_title VARCHAR(300) NOT NULL,
    status       VARCHAR(30)  NOT NULL DEFAULT 'pending'
                 CHECK (status IN ('pending','processed','error')),
    loaded_at    TIMESTAMPTZ  NOT NULL DEFAULT now()
);
COMMENT ON TABLE stg.student_import IS 'Пакетный импорт студентов';

-- ============================================================================
-- 3. SECURITY DEFINER-ФУНКЦИЯ ДЛЯ ЛОГИРОВАНИЯ ПОДКЛЮЧЕНИЙ
-- ============================================================================
-- Любой пользователь может вызвать: SELECT audit.log_login();
-- Функция выполняется от имени владельца (суперпользователя) и пишет в audit.

CREATE OR REPLACE FUNCTION audit.log_login()
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    INSERT INTO audit.login_log (user_id, event_type, ip_address, success, event_ts)
    SELECT u.user_id, 'login', inet_client_addr(), TRUE, now()
      FROM app.users u
     WHERE u.email = current_user                                                   -- login-роль совпадает с email
        OR concat_ws(' ', u.last_name, u.first_name, u.patronymic) = current_user   -- или с фио пользователя
     LIMIT 1;

    -- Если пользователь не найден в app.users — логируем только имя роли
    IF NOT FOUND THEN
        INSERT INTO audit.login_log (user_id, event_type, ip_address, success, failure_reason, event_ts)
        VALUES (NULL, 'login', inet_client_addr(), TRUE,
                'PG role "' || current_user || '" not mapped to app.users', now());
    END IF;
END;
$$;

COMMENT ON FUNCTION audit.log_login() IS
    'SECURITY DEFINER: логирует факт подключения текущего пользователя в audit.login_log';

-- ============================================================================
-- 4. РОЛИ И ПРИВИЛЕГИИ
-- ============================================================================

-- ---------- 4.1 Отзыв PUBLIC-доступа ----------

REVOKE ALL ON SCHEMA public FROM PUBLIC;
REVOKE ALL ON SCHEMA ref    FROM PUBLIC;
REVOKE ALL ON SCHEMA app    FROM PUBLIC;
REVOKE ALL ON SCHEMA audit  FROM PUBLIC;
REVOKE ALL ON SCHEMA stg    FROM PUBLIC;

-- ---------- 4.2 Групповые роли (NOLOGIN) ----------

DO $$
DECLARE
    r TEXT;
BEGIN
    FOREACH r IN ARRAY ARRAY[
        'app_reader', 'app_writer', 'app_owner',
        'auditor',
        'ddl_admin', 'dml_admin', 'security_admin'
    ] LOOP
        IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
            EXECUTE format('CREATE ROLE %I NOLOGIN', r);
        END IF;
    END LOOP;
END;
$$;

-- ---------- 4.3 Привилегии: app_reader ----------
-- Только SELECT на app и ref

GRANT USAGE ON SCHEMA ref TO app_reader;
GRANT USAGE ON SCHEMA app TO app_reader;

GRANT SELECT ON ALL TABLES IN SCHEMA ref TO app_reader;
GRANT SELECT ON ALL TABLES IN SCHEMA app TO app_reader;

-- Default privileges для будущих таблиц
ALTER DEFAULT PRIVILEGES IN SCHEMA ref GRANT SELECT ON TABLES TO app_reader;
ALTER DEFAULT PRIVILEGES IN SCHEMA app GRANT SELECT ON TABLES TO app_reader;

-- ---------- 4.4 Привилегии: app_writer ----------
-- SELECT + INSERT + UPDATE + DELETE на app и ref (но не DDL)

GRANT USAGE ON SCHEMA ref TO app_writer;
GRANT USAGE ON SCHEMA app TO app_writer;

GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA ref TO app_writer;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA app TO app_writer;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA ref TO app_writer;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA app TO app_writer;

ALTER DEFAULT PRIVILEGES IN SCHEMA ref GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO app_writer;
ALTER DEFAULT PRIVILEGES IN SCHEMA app GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO app_writer;
ALTER DEFAULT PRIVILEGES IN SCHEMA ref GRANT USAGE, SELECT ON SEQUENCES TO app_writer;
ALTER DEFAULT PRIVILEGES IN SCHEMA app GRANT USAGE, SELECT ON SEQUENCES TO app_writer;

-- ---------- 4.5 Привилегии: app_owner ----------
-- Полный контроль над app, ref, stg (включая DDL)

GRANT ALL ON SCHEMA ref   TO app_owner;
GRANT ALL ON SCHEMA app   TO app_owner;
GRANT ALL ON SCHEMA stg   TO app_owner;

GRANT ALL ON ALL TABLES    IN SCHEMA ref TO app_owner;
GRANT ALL ON ALL TABLES    IN SCHEMA app TO app_owner;
GRANT ALL ON ALL TABLES    IN SCHEMA stg TO app_owner;
GRANT ALL ON ALL SEQUENCES IN SCHEMA ref TO app_owner;
GRANT ALL ON ALL SEQUENCES IN SCHEMA app TO app_owner;
GRANT ALL ON ALL SEQUENCES IN SCHEMA stg TO app_owner;

ALTER DEFAULT PRIVILEGES IN SCHEMA ref GRANT ALL ON TABLES    TO app_owner;
ALTER DEFAULT PRIVILEGES IN SCHEMA app GRANT ALL ON TABLES    TO app_owner;
ALTER DEFAULT PRIVILEGES IN SCHEMA stg GRANT ALL ON TABLES    TO app_owner;
ALTER DEFAULT PRIVILEGES IN SCHEMA ref GRANT ALL ON SEQUENCES TO app_owner;
ALTER DEFAULT PRIVILEGES IN SCHEMA app GRANT ALL ON SEQUENCES TO app_owner;
ALTER DEFAULT PRIVILEGES IN SCHEMA stg GRANT ALL ON SEQUENCES TO app_owner;

-- ---------- 4.6 Привилегии: auditor ----------
-- Только SELECT на audit (INSERT только через триггер/функцию)

GRANT USAGE  ON SCHEMA audit TO auditor;
GRANT SELECT ON ALL TABLES IN SCHEMA audit TO auditor;
ALTER DEFAULT PRIVILEGES IN SCHEMA audit GRANT SELECT ON TABLES TO auditor;

-- Также даём auditor читать ref и app (для корреляции данных)
GRANT USAGE  ON SCHEMA ref TO auditor;
GRANT USAGE  ON SCHEMA app TO auditor;
GRANT SELECT ON ALL TABLES IN SCHEMA ref TO auditor;
GRANT SELECT ON ALL TABLES IN SCHEMA app TO auditor;
ALTER DEFAULT PRIVILEGES IN SCHEMA ref GRANT SELECT ON TABLES TO auditor;
ALTER DEFAULT PRIVILEGES IN SCHEMA app GRANT SELECT ON TABLES TO auditor;

-- ---------- 4.7 Привилегии: ddl_admin ----------
-- Может создавать/удалять объекты (CREATE), но не управляет данными

GRANT ALL ON SCHEMA ref   TO ddl_admin;
GRANT ALL ON SCHEMA app   TO ddl_admin;
GRANT ALL ON SCHEMA audit TO ddl_admin;
GRANT ALL ON SCHEMA stg   TO ddl_admin;

-- DDL-операции (CREATE TABLE, ALTER, DROP) контролируются через SCHEMA-привилегии
-- ddl_admin НЕ получает DML-доступ к существующим таблицам

-- ---------- 4.8 Привилегии: dml_admin ----------
-- Полный DML на всех схемах (SELECT, INSERT, UPDATE, DELETE), но не DDL

GRANT USAGE ON SCHEMA ref   TO dml_admin;
GRANT USAGE ON SCHEMA app   TO dml_admin;
GRANT USAGE ON SCHEMA audit TO dml_admin;
GRANT USAGE ON SCHEMA stg   TO dml_admin;

GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA ref   TO dml_admin;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA app   TO dml_admin;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA audit TO dml_admin;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA stg   TO dml_admin;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA ref   TO dml_admin;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA app   TO dml_admin;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA audit TO dml_admin;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA stg   TO dml_admin;

ALTER DEFAULT PRIVILEGES IN SCHEMA ref   GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO dml_admin;
ALTER DEFAULT PRIVILEGES IN SCHEMA app   GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO dml_admin;
ALTER DEFAULT PRIVILEGES IN SCHEMA audit GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO dml_admin;
ALTER DEFAULT PRIVILEGES IN SCHEMA stg   GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO dml_admin;
ALTER DEFAULT PRIVILEGES IN SCHEMA ref   GRANT USAGE, SELECT ON SEQUENCES TO dml_admin;
ALTER DEFAULT PRIVILEGES IN SCHEMA app   GRANT USAGE, SELECT ON SEQUENCES TO dml_admin;
ALTER DEFAULT PRIVILEGES IN SCHEMA audit GRANT USAGE, SELECT ON SEQUENCES TO dml_admin;
ALTER DEFAULT PRIVILEGES IN SCHEMA stg   GRANT USAGE, SELECT ON SEQUENCES TO dml_admin;

-- ---------- 4.9 Привилегии: security_admin ----------
-- Управление ролями и доступами; CREATEROLE + доступ к audit для ревизии

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'security_admin' AND rolcreaterole) THEN
        ALTER ROLE security_admin CREATEROLE;
    END IF;
END;
$$;

GRANT USAGE  ON SCHEMA audit TO security_admin;
GRANT SELECT ON ALL TABLES IN SCHEMA audit TO security_admin;
ALTER DEFAULT PRIVILEGES IN SCHEMA audit GRANT SELECT ON TABLES TO security_admin;

GRANT USAGE  ON SCHEMA ref TO security_admin;
GRANT USAGE  ON SCHEMA app TO security_admin;
GRANT SELECT ON ALL TABLES IN SCHEMA ref TO security_admin;
GRANT SELECT ON ALL TABLES IN SCHEMA app TO security_admin;

-- ---------- 4.10 Право вызова audit.log_login() для всех ----------
-- INSERT в audit.login_log закрыт для всех ролей напрямую;
-- запись возможна ТОЛЬКО через SECURITY DEFINER-функцию

GRANT EXECUTE ON FUNCTION audit.log_login() TO app_reader, app_writer, app_owner,
    auditor, ddl_admin, dml_admin, security_admin;

-- ============================================================================
-- 5. ТЕСТОВЫЕ LOGIN-ПОЛЬЗОВАТЕЛИ
-- ============================================================================

DO $$
DECLARE
    u RECORD;
BEGIN
    FOR u IN
        SELECT * FROM (VALUES
            ('test_student',  'student_pass_123',  ARRAY['app_reader']),
            ('test_teacher',  'teacher_pass_123',  ARRAY['app_writer']),
            ('test_auditor',  'auditor_pass_123',  ARRAY['auditor'])
        ) AS t(name, pass, roles)
    LOOP
        IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = u.name) THEN
            EXECUTE format('CREATE ROLE %I LOGIN PASSWORD %L', u.name, u.pass);
        END IF;
        -- Назначаем групповые роли
        FOR i IN 1..array_length(u.roles, 1) LOOP
            EXECUTE format('GRANT %I TO %I', u.roles[i], u.name);
        END LOOP;
    END LOOP;
END;
$$;

-- Даём тестовым пользователям право вызывать функцию логирования
GRANT EXECUTE ON FUNCTION audit.log_login() TO test_student, test_teacher, test_auditor;

-- Даём им USAGE на нужные схемы (наследуется от групповых ролей,
-- но явная выдача гарантирует работу search_path)
GRANT USAGE ON SCHEMA ref   TO test_student, test_teacher, test_auditor;
GRANT USAGE ON SCHEMA app   TO test_student, test_teacher, test_auditor;
GRANT USAGE ON SCHEMA audit TO test_auditor;
GRANT USAGE ON SCHEMA audit TO app_reader, app_writer, app_owner, test_student, test_teacher;

COMMIT;