-- Жизненный цикл экзаменационной попытки:
--   app.start_exam_session(exam_id)                     — студент начинает попытку
--   app.submit_answer(session_id, question_id, answer)  — студент отвечает на вопрос
--   app.finalize_exam_result(session_id, comment)       — преподаватель выставляет результат

-- Коды бизнес-ошибок (SQLSTATE):
--   LMS01 — роль БД не сопоставлена с пользователем платформы / учётная запись заблокирована
--   LMS02 — операция недоступна для роли пользователя на платформе
--   LMS03 — некорректные входные данные
--   LMS04 — объект не найден
--   LMS05 — нет доступа к объекту (не записан на курс / чужая сессия / не автор курса)
--   LMS06 — конфликт состояния (попытка уже есть, сессия не активна, результат уже выставлен)
--   LMS07 — истекло время экзамена

BEGIN;

-- Вспомогательная функция: определение вызывающего пользователя

CREATE OR REPLACE FUNCTION app.resolve_caller(p_expected_role TEXT)
RETURNS UUID
LANGUAGE plpgsql
AS $$
DECLARE
    v_user_id   UUID;
    v_is_active BOOLEAN;
    v_role_code TEXT;
BEGIN
    SELECT u.user_id, u.is_active, r.code
    INTO v_user_id, v_is_active, v_role_code
    FROM app.users u
    JOIN ref.roles r ON r.role_id = u.role_id
    WHERE u.email = session_user::text;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Роль БД «%» не сопоставлена ни с одним пользователем платформы', session_user
              USING ERRCODE = 'LMS01';
    END IF;

    IF NOT v_is_active THEN
        RAISE EXCEPTION 'Учётная запись «%» заблокирована', session_user
              USING ERRCODE = 'LMS01';
    END IF;

    IF v_role_code IS DISTINCT FROM p_expected_role THEN
        RAISE EXCEPTION 'Операция доступна только для роли «%», ваша роль на платформе — «%»',
                        p_expected_role, v_role_code
              USING ERRCODE = 'LMS02';
    END IF;

    RETURN v_user_id;
END;
$$;

COMMENT ON FUNCTION app.resolve_caller(TEXT) IS
    'Сопоставляет session_user с app.users.email и проверяет роль на платформе';

REVOKE ALL ON FUNCTION app.resolve_caller(TEXT) FROM PUBLIC;


-- app.start_exam_session — студент начинает попытку сдачи экзамена

CREATE OR REPLACE FUNCTION app.start_exam_session(
    p_exam_id UUID,
    OUT ok      BOOLEAN,
    OUT message TEXT,
    OUT data    JSONB
)
RETURNS RECORD
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    c_fn       CONSTANT TEXT := 'app.start_exam_session';
    v_params   JSONB := jsonb_build_object('exam_id', p_exam_id);
    v_user_id  UUID;
    v_exam     RECORD;
    v_session  UUID;
    v_token    TEXT;
    v_err_code TEXT;
    v_err_msg  TEXT;
BEGIN
    BEGIN  -- подтранзакция: при ошибке все изменения внутри блока откатываются
        v_user_id := app.resolve_caller('student');

        IF p_exam_id IS NULL THEN
            RAISE EXCEPTION 'Не указан идентификатор экзамена' USING ERRCODE = 'LMS03';
        END IF;

        SELECT e.exam_id, e.course_id, e.title, e.duration_minutes
        INTO v_exam
        FROM app.exams e
        WHERE e.exam_id = p_exam_id;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'Экзамен с идентификатором % не найден', p_exam_id USING ERRCODE = 'LMS04';
        END IF;

        IF NOT EXISTS (SELECT 1
                        FROM app.course_enrollments ce
                        WHERE ce.user_id = v_user_id
                        AND ce.course_id = v_exam.course_id) THEN
            RAISE EXCEPTION 'Вы не записаны на курс, к которому относится экзамен «%»', v_exam.title
            USING ERRCODE = 'LMS05';
        END IF;

        IF NOT EXISTS (SELECT 1
                        FROM app.exam_questions q
                        WHERE q.exam_id = p_exam_id) THEN
            RAISE EXCEPTION 'Экзамен «%» не содержит вопросов и не может быть начат', v_exam.title
            USING ERRCODE = 'LMS06';
        END IF;

        IF EXISTS (SELECT 1
                    FROM app.exam_sessions s
                    WHERE s.user_id = v_user_id
                    AND s.exam_id = p_exam_id
                    AND s.status IN ('in_progress', 'completed')) THEN
            RAISE EXCEPTION 'У вас уже есть активная или завершённая попытка по экзамену «%»', v_exam.title
            USING ERRCODE = 'LMS06';
        END IF;

        v_token := replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '');

        -- Активируем запланированную сессию, если она есть
        UPDATE app.exam_sessions s
            SET status = 'in_progress',
                started_at = now(),
                finished_at = NULL,
                session_token = v_token
        WHERE s.session_id = (SELECT s2.session_id
                                FROM app.exam_sessions s2
                                WHERE s2.user_id = v_user_id
                                AND s2.exam_id = p_exam_id
                                AND s2.status  = 'scheduled'
                                LIMIT 1
                                FOR UPDATE)
        RETURNING s.session_id INTO v_session;

        -- Иначе создаём новую
        IF v_session IS NULL THEN
            INSERT INTO app.exam_sessions (exam_id, user_id, status, session_token, started_at)
            VALUES (p_exam_id, v_user_id, 'in_progress', v_token, now())
            RETURNING session_id INTO v_session;
        END IF;

        ok := TRUE;
        message := format('Попытка начата: экзамен «%s», ограничение по времени — %s мин.',
                          v_exam.title, v_exam.duration_minutes);
        data := jsonb_build_object(
                       'session_id',    v_session,
                       'session_token', v_token,
                       'deadline',      now() + v_exam.duration_minutes * interval '1 minute');
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS v_err_code = RETURNED_SQLSTATE, v_err_msg = MESSAGE_TEXT;
        ok := FALSE;
        message := CASE WHEN v_err_code LIKE 'LMS%' THEN v_err_msg
                        ELSE 'Внутренняя ошибка при выполнении операции, обратитесь к администратору (код ' || v_err_code || ')' END;
        data := jsonb_build_object('error_code', v_err_code);
    END;

    -- Журналирование каждого вызова
    PERFORM audit.log_function_call(c_fn, v_params, ok, v_err_code, v_err_msg);

    IF NOT ok THEN
        RAISE WARNING '[%] %', v_err_code, message;
    END IF;
END;
$$;

COMMENT ON FUNCTION app.start_exam_session(UUID) IS
    'SECURITY DEFINER: студент начинает попытку сдачи экзамена (проверка записи на курс, отсутствия повторной попытки)';


-- app.submit_answer — студент отвечает на вопрос

CREATE OR REPLACE FUNCTION app.submit_answer(
    p_session_id  UUID,
    p_question_id UUID,
    p_answer      JSONB,
    OUT ok        BOOLEAN,
    OUT message   TEXT,
    OUT data      JSONB
)
RETURNS  RECORD
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    c_fn       CONSTANT TEXT := 'app.submit_answer';
    v_params   JSONB := jsonb_build_object('session_id',  p_session_id,
                                           'question_id', p_question_id,
                                           'answer',      p_answer);
    v_user_id  UUID;
    v_sess     RECORD;
    v_q        RECORD;
    v_points   INT;
    v_answer   UUID;
    v_err_code TEXT;
    v_err_msg  TEXT;
BEGIN
    BEGIN
        v_user_id := app.resolve_caller('student');

        IF p_session_id IS NULL OR p_question_id IS NULL OR p_answer IS NULL THEN
            RAISE EXCEPTION 'Параметры session_id, question_id и answer обязательны' USING ERRCODE = 'LMS03';
        END IF;

        SELECT s.session_id, s.exam_id, s.status, s.started_at, e.duration_minutes
        INTO v_sess
        FROM app.exam_sessions s
        JOIN app.exams e ON e.exam_id = s.exam_id
        WHERE s.session_id = p_session_id
        AND s.user_id = v_user_id
        FOR UPDATE OF s;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'Сессия % не найдена или принадлежит другому пользователю', p_session_id
            USING ERRCODE = 'LMS05';
        END IF;
        
        IF v_sess.status <> 'in_progress' THEN
            RAISE EXCEPTION 'Ответы принимаются только в активной сессии; текущий статус — «%»', v_sess.status
            USING ERRCODE = 'LMS06';
        END IF;

        IF now() > v_sess.started_at + v_sess.duration_minutes * interval '1 minute' THEN
            RAISE EXCEPTION 'Время экзамена истекло в %',
            to_char(v_sess.started_at + v_sess.duration_minutes * interval '1 minute', 'DD.MM.YYYY HH24:MI')
            USING ERRCODE = 'LMS07';
        END IF;

        SELECT q.question_id, q.options, q.correct_answer, q.points
        INTO v_q
        FROM app.exam_questions q
        WHERE q.question_id = p_question_id
        AND q.exam_id = v_sess.exam_id;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'Вопрос % не относится к экзамену этой сессии', p_question_id
            USING ERRCODE = 'LMS04';
        END IF;

        IF jsonb_typeof(p_answer) <> 'string' THEN
            RAISE EXCEPTION 'Ответ должен быть JSON-строкой, получено: %', jsonb_typeof(p_answer)
            USING ERRCODE = 'LMS03';
        END IF;

        IF jsonb_array_length(v_q.options) > 0 AND NOT (v_q.options ? (p_answer #>> '{}')) THEN
            RAISE EXCEPTION 'Вариант ответа «%» отсутствует среди допустимых вариантов вопроса', p_answer #>> '{}'
            USING ERRCODE = 'LMS03';
        END IF;

        v_points := CASE WHEN p_answer = v_q.correct_answer THEN v_q.points ELSE 0 END;

        INSERT INTO app.session_answers (session_id, question_id, answer_payload, awarded_points, answered_at)
        VALUES (p_session_id, p_question_id, p_answer, v_points, now())
        ON CONFLICT (session_id, question_id) DO UPDATE
            SET answer_payload = EXCLUDED.answer_payload,
                awarded_points = EXCLUDED.awarded_points,
                answered_at = EXCLUDED.answered_at
        RETURNING answer_id INTO v_answer;

        ok := TRUE;
        message := 'Ответ принят';
        data := jsonb_build_object('answer_id', v_answer);  -- баллы и правильный ответ не раскрываются
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS v_err_code = RETURNED_SQLSTATE, v_err_msg = MESSAGE_TEXT;
        ok := FALSE;
        message := CASE WHEN v_err_code LIKE 'LMS%' THEN v_err_msg
                        ELSE 'Внутренняя ошибка при выполнении операции, обратитесь к администратору (код ' || v_err_code || ')' END;
        data := jsonb_build_object('error_code', v_err_code);
    END;

    PERFORM audit.log_function_call(c_fn, v_params, ok, v_err_code, v_err_msg);

    IF NOT ok THEN
        RAISE WARNING '[%] %', v_err_code, message;
    END IF;
END;
$$;

COMMENT ON FUNCTION app.submit_answer(UUID, UUID, JSONB) IS
    'SECURITY DEFINER: студент отвечает на вопрос; баллы начисляются автоматически';


-- app.finalize_exam_result — преподаватель выставляет итог за сессию

CREATE OR REPLACE FUNCTION app.finalize_exam_result(
    p_session_id UUID,
    p_comment    TEXT DEFAULT NULL,
    OUT ok       BOOLEAN,
    OUT message  TEXT,
    OUT data     JSONB
)
RETURNS RECORD
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    c_fn       CONSTANT TEXT := 'app.finalize_exam_result';
    v_params   JSONB := jsonb_build_object('session_id', p_session_id,
                                           'comment', left(p_comment, 200));
    v_user_id  UUID;
    v_s        RECORD;
    v_closed   BOOLEAN := FALSE;
    v_total    INT;
    v_passed   BOOLEAN;
    v_result   UUID;
    v_err_code TEXT;
    v_err_msg  TEXT;
BEGIN
    BEGIN
        v_user_id := app.resolve_caller('teacher');

        IF p_session_id IS NULL THEN
            RAISE EXCEPTION 'Не указан идентификатор сессии (session_id)' USING ERRCODE = 'LMS03';
        END IF;

        IF length(p_comment) > 2000 THEN
            RAISE EXCEPTION 'Комментарий слишком длинный: % символов (допустимо не более 2000)', length(p_comment)
            USING ERRCODE = 'LMS03';
        END IF;

        SELECT s.session_id, s.status, s.started_at, e.title, e.max_score,
               e.passing_score, e.duration_minutes, c.created_by
        INTO v_s
        FROM app.exam_sessions s
        JOIN app.exams e ON e.exam_id = s.exam_id
        JOIN app.courses c ON c.course_id = e.course_id
        WHERE s.session_id = p_session_id
        FOR UPDATE OF s;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'Сессия % не найдена', p_session_id USING ERRCODE = 'LMS04';
        END IF;

        IF v_s.created_by <> v_user_id THEN
            RAISE EXCEPTION 'Вы не являетесь автором курса, к которому относится экзамен «%»', v_s.title
            USING ERRCODE = 'LMS05';
        END IF;

        IF EXISTS (SELECT 1
                    FROM app.exam_results r
                    WHERE r.session_id = p_session_id) THEN
            RAISE EXCEPTION 'Результат по сессии % уже выставлен, повторное выставление запрещено', p_session_id
            USING ERRCODE = 'LMS06';
        END IF;

        IF v_s.status NOT IN ('in_progress', 'completed') THEN
            RAISE EXCEPTION 'Нельзя выставить результат для сессии в статусе «%»', v_s.status
            USING ERRCODE = 'LMS06';
        END IF;

        -- Закрытие активной сессии (просроченная по дедлайну)
        IF v_s.status = 'in_progress' THEN
            UPDATE app.exam_sessions s
            SET status = 'completed',
                finished_at = LEAST(now(), v_s.started_at + v_s.duration_minutes * interval '1 minute')
            WHERE s.session_id = p_session_id;
            v_closed := TRUE;
        END IF;

        SELECT COALESCE(SUM(a.awarded_points), 0)
        INTO v_total
        FROM app.session_answers a
        WHERE a.session_id = p_session_id;

        v_total := LEAST(v_total, v_s.max_score);
        v_passed := v_total >= v_s.passing_score;

        INSERT INTO app.exam_results (session_id, total_score, passed, teacher_comment)
        VALUES (p_session_id, v_total, v_passed, NULLIF(btrim(p_comment), ''))
        RETURNING result_id INTO v_result;

        ok := TRUE;
        message := format('Результат выставлен: %s из %s (порог %s) — %s',
                            v_total, v_s.max_score, v_s.passing_score,
                            CASE WHEN v_passed THEN 'зачтено' ELSE 'не зачтено' END);
        data := jsonb_build_object('result_id', v_result,
                                    'total_score', v_total,
                                    'passed', v_passed,
                                    'session_closed', v_closed);
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS v_err_code = RETURNED_SQLSTATE, v_err_msg = MESSAGE_TEXT;
        ok  := FALSE;
        message := CASE WHEN v_err_code LIKE 'LMS%' THEN v_err_msg
                        ELSE 'Внутренняя ошибка при выполнении операции, обратитесь к администратору (код ' || v_err_code || ')' END;
        data := jsonb_build_object('error_code', v_err_code);
    END;

    PERFORM audit.log_function_call(c_fn, v_params, ok, v_err_code, v_err_msg);

    IF NOT ok THEN
        RAISE WARNING '[%] %', v_err_code, message;
    END IF;
END;
$$;

COMMENT ON FUNCTION app.finalize_exam_result(UUID, TEXT) IS
    'SECURITY DEFINER: преподаватель-автор курса выставляет результат; балл и зачёт вычисляет система';


-- Права на выполнение

-- По умолчанию EXECUTE на новые функции есть у PUBLIC — отзываем.
REVOKE ALL ON FUNCTION app.start_exam_session(UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION app.submit_answer(UUID, UUID, JSONB) FROM PUBLIC;
REVOKE ALL ON FUNCTION app.finalize_exam_result(UUID, TEXT) FROM PUBLIC;

-- Студенческие операции — группе app_reader
GRANT EXECUTE ON FUNCTION app.start_exam_session(UUID) TO app_reader;
GRANT EXECUTE ON FUNCTION app.submit_answer(UUID, UUID, JSONB) TO app_reader;

-- Преподавательская операция — группе app_writer
GRANT EXECUTE ON FUNCTION app.finalize_exam_result(UUID, TEXT) TO app_writer;

COMMIT;