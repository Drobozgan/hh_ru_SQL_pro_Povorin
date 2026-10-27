SET search_path = hh_school;

--А1--
SELECT 
    'Событие до отклика или без ключа' AS problem_type, 
    COUNT(*) AS rows_count
FROM messages m
LEFT JOIN responses r ON m.response_id = r.response_id
WHERE m.sent_at < r.created_at OR m.response_id IS NULL

UNION ALL

SELECT 
    'Событие до отклика или без ключа' AS problem_type, 
    COUNT(*) AS rows_count,
    STRING_AGG(c.call_id::text, ', ') AS problem_ids
FROM calls c
LEFT JOIN responses r ON c.response_id = r.response_id
WHERE c.call_at < r.created_at OR c.response_id IS NULL;
--ID проблемных звонков:700244, 700245, 700246, 700247, 700248, 700249, 700250, 700251

WITH valid_calls AS (
    SELECT call_duration
    FROM calls
    WHERE status = 'successful' AND call_duration IS NOT NULL
),
percentiles AS (
    SELECT 
        AVG(call_duration) AS avg_duration,
        PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY call_duration) AS median_duration,
        PERCENTILE_CONT(0.99) WITHIN GROUP (ORDER BY call_duration) AS p99_duration
    FROM valid_calls
)
SELECT 
    p.avg_duration,
    p.median_duration,
    p.p99_duration,
    (SELECT COUNT(*) FROM valid_calls WHERE call_duration > p.p99_duration) AS above_p99_count,
    (SELECT AVG(call_duration) FROM valid_calls WHERE call_duration <= p.p99_duration) AS avg_without_outliers
FROM percentiles p;
--Найдено 0 проблемных записей сообщений и 8 записей звонков
--эти ошибки влияют на сам факт коммуникации, так каак мы не можем привязывать событие к отклику, если оно произошло до него. Такие элементы нужно исключать из аналища
--средняя длительность звонка составила 467 сек, медиана 438 сек, а 99й перцентиль 890 сек
--количество звонков выше 99-го перцентиля: 2, Средняя длительность без их учета падает до 462 сек
--считаю значения выше 99-го перцентиля ошибками/выбросами (к примеру рекрутер забыл положить трубку)
--при расчете типичной длительности я бы опирался на медиану, так как она наиболее устойчива к выбросам


--Б2--
WITH messages_7d AS (
    SELECT 
        m.response_id, 
        m.employer_id, 
        m.message_id::text AS event_id, 
        m.sent_at AS event_at, 
        'message' AS event_type
    FROM messages m
    JOIN responses r ON m.response_id = r.response_id
    WHERE m.sender_role = 'employer' 
      AND m.sent_at >= r.created_at 
      AND m.sent_at <= r.created_at + INTERVAL '7 days'
),
calls_7d AS (
    SELECT 
        c.response_id, 
        c.employer_id, 
        c.call_id::text AS event_id, 
        c.call_at AS event_at, 
        'call' AS event_type
    FROM calls c
    JOIN responses r ON c.response_id = r.response_id
    WHERE c.caller_role = 'employer' 
      AND c.call_at >= r.created_at 
      AND c.call_at <= r.created_at + INTERVAL '7 days'
),
events AS (
    SELECT * FROM messages_7d
    UNION ALL
    SELECT * FROM calls_7d
)
SELECT 
    COUNT(*) AS total_events,
    COUNT(DISTINCT response_id) AS responses_with_comm,
    COUNT(*) FILTER (WHERE event_type = 'call') AS total_calls,
    COUNT(*) FILTER (WHERE event_type = 'message') AS total_messages
FROM events;
--общее количество событий за первые 7 дней = 1096
--Количество различных откликов с коммуникацией = 382
--из них звонков = 108, а сообщений =988
--наблюдение: работодатели значительно чаще используют сообщения для первичной связи с кандидатом
--это говорит о том, что асинхронный формат общения в чате является стандартом на рынке


--Б3--
WITH messages_7d AS (
    SELECT 
        m.response_id, 
        m.message_id::text AS event_id, 
        m.sent_at AS event_at, 
        'message' AS event_type
    FROM messages m
    JOIN responses r ON m.response_id = r.response_id
    WHERE m.sender_role = 'employer' 
      AND m.sent_at >= r.created_at 
      AND m.sent_at <= r.created_at + INTERVAL '7 days'
),
calls_7d AS (
    SELECT 
        c.response_id, 
        c.call_id::text AS event_id, 
        c.call_at AS event_at, 
        'call' AS event_type
    FROM calls c
    JOIN responses r ON c.response_id = r.response_id
    WHERE c.caller_role = 'employer' 
      AND c.call_at >= r.created_at 
      AND c.call_at <= r.created_at + INTERVAL '7 days'
),
events AS (
    SELECT * FROM messages_7d 
    UNION ALL 
    SELECT * FROM calls_7d
),

timeline AS (
    SELECT 
        response_id, 
        event_id, 
        event_at, 
        event_type,
        ROW_NUMBER() OVER w AS event_number,
        LAG(event_at) OVER w AS prev_event_at,
        LEAD(event_type) OVER w AS next_event_type,
        COUNT(*) OVER (
            PARTITION BY response_id 
            ORDER BY event_at, event_type, event_id 
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) AS comms_so_far,
        FIRST_VALUE(event_type) OVER w AS first_comm_type,
        LAST_VALUE(event_type) OVER (
            PARTITION BY response_id 
            ORDER BY event_at, event_type, event_id 
            ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
        ) AS last_comm_type
    FROM events
    WINDOW w AS (PARTITION BY response_id ORDER BY event_at, event_type, event_id)
),

response_mart AS (
    SELECT 
        r.response_id, 
        v.employer_id, 
        v.professional_role,
        r.status,
        COUNT(t.event_id) AS total_comms,
        COUNT(t.event_id) FILTER (WHERE t.event_type = 'call') AS total_calls,
        COUNT(t.event_id) FILTER (WHERE t.event_type = 'message') AS total_messages,
        MIN(t.event_at) AS first_comm_at,
        MAX(t.first_comm_type) AS first_comm_type,
        MAX(t.event_type) FILTER (WHERE t.event_number = 2) AS second_comm_type,
        MAX(t.last_comm_type) AS last_comm_type,
        EXTRACT(EPOCH FROM (MIN(t.event_at) - r.created_at)) / 3600.0 AS hours_to_first_comm,
        MAX(EXTRACT(EPOCH FROM (t.event_at - t.prev_event_at)) / 3600.0) AS max_interval_hours
    FROM responses r
    JOIN vacancies v ON r.vacancy_id = v.vacancy_id
    LEFT JOIN timeline t ON r.response_id = t.response_id
    GROUP BY r.response_id, v.employer_id, v.professional_role, r.status, r.created_at
)
SELECT 
    COUNT(*) AS total_rows,
    COUNT(*) FILTER (WHERE total_comms > 0) AS responses_with_comm,
    COUNT(*) FILTER (WHERE total_comms = 0) AS responses_without_comm,
    COUNT(*) FILTER (WHERE first_comm_type = 'message') AS first_msg,
    COUNT(*) FILTER (WHERE first_comm_type = 'call') AS first_call
FROM response_mart;
--собрана единая витрина на 628 строк (т.е.628 откликов)
--количество откликов с коммуникацией = 382, а без 246
--первой коммуникацией было сообщение в 314 случаях, а звонок в 68 случаях.
--доля откликов без коммуникаций за первые 7 дней составляет примерно 39%
--рработодатели преимущественно начинают контакт через сообщения


--В4--
WITH comms_7d AS (
    SELECT 
        m.response_id, 
        m.sent_at AS event_at
    FROM messages m
    JOIN responses r ON m.response_id = r.response_id
    WHERE m.sender_role = 'employer' 
      AND m.sent_at >= r.created_at 
      AND m.sent_at <= r.created_at + INTERVAL '7 days'
    
    UNION ALL

    SELECT 
        c.response_id, 
        c.call_at AS event_at
    FROM calls c
    JOIN responses r ON c.response_id = r.response_id
    WHERE c.caller_role = 'employer' 
      AND c.call_at >= r.created_at 
      AND c.call_at <= r.created_at + INTERVAL '7 days'
),
response_mart AS (
    SELECT 
        r.response_id, 
        v.employer_id, 
        v.professional_role,
        r.status,
        MIN(c.event_at) AS first_comm_at,
        COUNT(c.event_at) AS total_comms,
        EXTRACT(EPOCH FROM (MIN(c.event_at) - r.created_at)) / 3600.0 AS hours_to_first_comm
    FROM responses r
    JOIN vacancies v ON r.vacancy_id = v.vacancy_id
    LEFT JOIN comms_7d c ON r.response_id = c.response_id
    GROUP BY r.response_id, v.employer_id, v.professional_role, r.status, r.created_at
),
employer_stats AS (
    SELECT 
        professional_role, 
        employer_id,
        COUNT(*) AS total_responses,
        COUNT(*) FILTER (WHERE total_comms > 0) AS processed_responses,
        ROUND(100.0 * COUNT(*) FILTER (WHERE total_comms > 0) / COUNT(*), 2) AS processed_share,
        PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY hours_to_first_comm) AS median_hours_to_first_comm,
        PERCENTILE_CONT(0.9) WITHIN GROUP (ORDER BY hours_to_first_comm) AS p90_hours_to_first_comm,
        ROUND(100.0 * COUNT(*) FILTER (WHERE status = 'invited') / COUNT(*), 2) AS invite_conversion_pct
    FROM response_mart
    GROUP BY professional_role, employer_id
    HAVING COUNT(*) >= 8
),
ranked_employers AS (
    SELECT 
        professional_role,
        employer_id,
        DENSE_RANK() OVER (
            PARTITION BY professional_role 
            ORDER BY processed_share DESC, median_hours_to_first_comm ASC
        ) AS rank_value
    FROM employer_stats
)
SELECT 
    professional_role, 
    rank_value, 
    employer_id
FROM ranked_employers
WHERE rank_value IN (1, 2)
ORDER BY professional_role, rank_value, employer_id;
--Аналитик данных: 1 место  employer_id 109, 2 место - employer_id 103
--Дата-инденер: 1 место - employer_id 106, 2 место - employer_id 101
--Продуктовый аналитик: 1 место - employer_id 103, 2 место - employer_id 102
--Разработчки: 1 место - employer_id 112, 2 место - employer_id 104
--Тестировщик: 1 место - employer_id 107, 2 место - employer_id 108

--В5--
WITH message_timeline AS (
    SELECT 
        m.response_id, 
        m.employer_id, 
        m.sender_role, 
        m.sent_at,
        LAG(m.sender_role) OVER (PARTITION BY m.response_id ORDER BY m.sent_at, m.message_id) AS prev_sender,
        LAG(m.sent_at) OVER (PARTITION BY m.response_id ORDER BY m.sent_at, m.message_id) AS prev_sent_at
    FROM messages m
    JOIN responses r ON m.response_id = r.response_id
    WHERE m.sent_at >= r.created_at AND m.sent_at <= r.created_at + INTERVAL '7 days'
),
employer_responses AS (
    SELECT 
        employer_id, 
        EXTRACT(EPOCH FROM (sent_at - prev_sent_at))/3600 AS response_hours
    FROM message_timeline
    WHERE sender_role = 'employer' AND prev_sender = 'applicant'
),
employer_speed AS (
    SELECT 
        employer_id,
        COUNT(*) AS measured_answers_count,
        AVG(response_hours) AS avg_response_time,
        PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY response_hours) AS median_response_time,
        PERCENTILE_CONT(0.9) WITHIN GROUP (ORDER BY response_hours) AS p90_response_time
    FROM employer_responses
    GROUP BY employer_id
)
SELECT *
FROM employer_speed
ORDER BY median_response_time ASC;
--общее количество найденных ответов (когда работодатель пишет сразу после кандидата)= 588
--работодатель с минимальной медианой - 107, значение его медианы = 3.93 часов