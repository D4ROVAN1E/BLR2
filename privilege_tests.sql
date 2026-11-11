DELETE FROM app.exam_results    WHERE session_id = '66666666-0000-0000-0000-000000000012';
DELETE FROM app.session_answers WHERE session_id = '66666666-0000-0000-0000-000000000012';
UPDATE app.exam_sessions
   SET status        = 'scheduled',
       started_at    = NULL,
       finished_at   = NULL,
       session_token = 'sess_token_hash_12_f6c2bc'
 WHERE session_id = '66666666-0000-0000-0000-000000000012';


SET SESSION AUTHORIZATION test_student;

SELECT course_id, title 
FROM app.courses 
LIMIT 2;

RESET SESSION AUTHORIZATION;


SET SESSION AUTHORIZATION test_teacher;

DROP TABLE app.exam_results;

RESET SESSION AUTHORIZATION;


SET SESSION AUTHORIZATION test_auditor;

INSERT INTO audit.function_calls (function_name, success) 
VALUES ('app.fake_call', true);

RESET SESSION AUTHORIZATION;


SET SESSION AUTHORIZATION test_student;

INSERT INTO app.exam_sessions (exam_id, user_id, status, session_token, started_at)
VALUES ('44444444-0000-0000-0000-000000000009', '11111111-0000-0000-0000-000000000005', 'in_progress', 'fake_token', now());

RESET SESSION AUTHORIZATION;


SET SESSION AUTHORIZATION test_student;

SELECT * FROM app.finalize_exam_result('66666666-0000-0000-0000-000000000012', 'Самооценка');

RESET SESSION AUTHORIZATION;


SET SESSION AUTHORIZATION test_student;

SELECT * FROM app.start_exam_session('44444444-0000-0000-0000-000000000005');

RESET SESSION AUTHORIZATION;


SET SESSION AUTHORIZATION test_student;

SELECT * FROM app.start_exam_session('44444444-0000-0000-0000-000000000009');

RESET SESSION AUTHORIZATION;


SET SESSION AUTHORIZATION test_student;

SELECT * FROM app.submit_answer(
    '66666666-0000-0000-0000-000000000012',
    '55555555-0000-0000-0000-000000000012',
    '"Недопустимый вариант"'::jsonb
);

RESET SESSION AUTHORIZATION;


SET SESSION AUTHORIZATION test_student;

SELECT * FROM app.submit_answer(
    '66666666-0000-0000-0000-000000000012',
    '55555555-0000-0000-0000-000000000010',
    '"SELECT"'::jsonb
);

RESET SESSION AUTHORIZATION;


SET SESSION AUTHORIZATION test_teacher;

SELECT * FROM app.finalize_exam_result(
    '66666666-0000-0000-0000-000000000001',
    'Попытка оценить чужой курс'
);

RESET SESSION AUTHORIZATION;


SET SESSION AUTHORIZATION test_teacher;

SELECT * FROM app.finalize_exam_result(
    '66666666-0000-0000-0000-000000000012',
    'Экзамен проверен преподавателем'
);

RESET SESSION AUTHORIZATION;


SET SESSION AUTHORIZATION test_auditor;

SELECT call_id,
       to_char(call_time, 'HH24:MI:SS') AS call_time,
       function_name,
       caller_role,
       success,
       COALESCE(error_code, '-') AS error_code,
       COALESCE(error_message, '-') AS error_message
FROM audit.function_calls
ORDER BY call_id DESC
LIMIT 8;

RESET SESSION AUTHORIZATION;