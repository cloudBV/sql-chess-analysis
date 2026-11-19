-- =============================================================================
-- Chess Game Analysis with PostgreSQL
-- Dataset : 40,038 Lichess games (Jan - Jul 2026), exported to tab-separated text
-- Tools   : PostgreSQL, pgAdmin 4
-- Author  : Yosef Setiawan (github.com/cloudBV)
--
-- HOW TO RUN
--   1. Create a database (e.g. chess_analysis) and open the Query Tool on it.
--   2. Run Section 0 to create the table.
--   3. Import games_export.txt (see the import note in Section 0).
--   4. Run Sections 1-7 in order. Each query is independent once the
--      games_clean view from Section 1 exists.
-- =============================================================================


-- =============================================================================
-- SECTION 0. SCHEMA AND IMPORT
-- =============================================================================

CREATE TABLE IF NOT EXISTS games (
    game_id      integer PRIMARY KEY,
    lichess_id   varchar(8),
    event        text,
    date         date,
    white        text,
    black        text,
    result       text,
    white_elo    integer,
    black_elo    integer,
    eco          varchar(3),
    opening      text,
    time_control text,
    termination  text,
    variant      text,
    num_plies    integer,
    movetext     text
);

-- Import (pgAdmin): right-click the table > Import/Export Data
--   Format: csv | Encoding: UTF8 | Header: Yes | Delimiter: \t | NULL strings: (empty)
-- Import (psql) instead:
--   \copy games FROM 'games_export.txt' WITH (FORMAT csv, DELIMITER E'\t', HEADER true, ENCODING 'UTF8')

-- Sanity check: expect 40038
SELECT count(*) AS total_games FROM games;


-- =============================================================================
-- SECTION 1. DATA QUALITY AUDIT AND CLEANING VIEW
-- Skills: CASE, FILTER, NULL handling, views
-- =============================================================================

-- 1a. Audit: how much of the raw data is unusable for analysis?
--     (categories overlap, so they do not sum to the total)
SELECT
    count(*)                                               AS total_games,
    count(*) FILTER (WHERE variant <> 'Standard')          AS non_standard_variant,
    count(*) FILTER (WHERE result NOT IN ('1-0','0-1','1/2-1/2','0.5-0.5')) AS unfinished_or_unknown_result,
    count(*) FILTER (WHERE result = '0.5-0.5')             AS malformed_draw_label,
    count(*) FILTER (WHERE termination = 'Unplayed')       AS unplayed,
    count(*) FILTER (WHERE white_elo IS NULL OR black_elo IS NULL
                        OR white_elo = 0 OR black_elo = 0)  AS missing_or_zero_elo,
    count(*) FILTER (WHERE white_elo = 0 OR black_elo = 0)  AS zero_elo_placeholder,
    count(*) FILTER (WHERE event ILIKE '%TCEC%'
                        OR white_elo > 3000 OR black_elo > 3000) AS engine_games,
    count(*) FILTER (WHERE time_control IS NULL)           AS missing_time_control
FROM games;

-- 1b. Cleaned view used by every analysis below.
--     * Standard chess only (Chess960 has different opening theory)
--     * Finished games only; '0.5-0.5' normalised to '1/2-1/2'
--     * Engine games removed (TCEC events / Elo above 3000): this analysis is
--       about human players
--     * Elo of 0 is a placeholder for "unrated", so it is converted to NULL
--     * white_score: 1 = White win, 0.5 = draw, 0 = Black win
CREATE OR REPLACE VIEW games_clean AS
SELECT
    game_id,
    lichess_id,
    event,
    date,
    white,
    black,
    CASE WHEN result = '0.5-0.5' THEN '1/2-1/2' ELSE result END AS result,
    CASE result
        WHEN '1-0'     THEN 1.0
        WHEN '0-1'     THEN 0.0
        WHEN '1/2-1/2' THEN 0.5
        WHEN '0.5-0.5' THEN 0.5
    END                                   AS white_score,
    nullif(white_elo, 0)                  AS white_elo,
    nullif(black_elo, 0)                  AS black_elo,
    nullif(white_elo, 0) - nullif(black_elo, 0) AS elo_diff,
    eco,
    left(eco, 1)                          AS eco_family,
    opening,
    time_control,
    num_plies,
    movetext
FROM games
WHERE variant = 'Standard'
  AND result IN ('1-0','0-1','1/2-1/2','0.5-0.5')
  AND coalesce(termination, '') <> 'Unplayed'
  AND coalesce(event, '') NOT ILIKE '%TCEC%'
  AND coalesce(white_elo, 0) <= 3000      -- coalesce: a NULL Elo must not drop the row
  AND coalesce(black_elo, 0) <= 3000;

-- 1c. How many rows survive cleaning?
SELECT
    (SELECT count(*) FROM games)       AS raw_games,
    (SELECT count(*) FROM games_clean) AS clean_games;

-- 1d. Overall result distribution (baseline for later sections)
SELECT
    result,
    count(*)                                              AS games,
    round(100.0 * count(*) / sum(count(*)) OVER (), 1)    AS pct
FROM games_clean
GROUP BY result
ORDER BY games DESC;


-- =============================================================================
-- SECTION 2. OPENING PERFORMANCE BY ECO FAMILY
-- Skills: CTE, RANK() OVER (PARTITION BY ...), HAVING
-- =============================================================================

-- ECO families: A = flank/irregular, B = semi-open (Sicilian, Caro-Kann...),
-- C = open games/French, D = closed/Queen's Gambit, E = Indian defences.
WITH opening_stats AS (
    SELECT
        eco_family,
        eco,
        opening,
        count(*)                                               AS games,
        round(avg(white_score)::numeric, 3)                    AS white_score,
        round(100.0 * avg((result = '1/2-1/2')::int), 1)       AS draw_pct,
        round(avg(num_plies) / 2.0, 1)                         AS avg_moves
    FROM games_clean
    GROUP BY eco_family, eco, opening
    HAVING count(*) >= 30           -- ignore tiny samples
)
SELECT
    *,
    rank() OVER (PARTITION BY eco_family ORDER BY white_score DESC) AS rank_in_family
FROM opening_stats
ORDER BY eco_family, rank_in_family;

-- 2b. Top 3 best and worst openings for White within each family
WITH opening_stats AS (
    SELECT eco_family, opening, count(*) AS games,
           round(avg(white_score)::numeric, 3) AS white_score
    FROM games_clean
    GROUP BY eco_family, opening
    HAVING count(*) >= 30
),
ranked AS (
    SELECT *,
           row_number() OVER (PARTITION BY eco_family ORDER BY white_score DESC) AS best_rank,
           row_number() OVER (PARTITION BY eco_family ORDER BY white_score ASC)  AS worst_rank
    FROM opening_stats
)
SELECT eco_family, opening, games, white_score,
       CASE WHEN best_rank <= 3 THEN 'best for White' ELSE 'worst for White' END AS category
FROM ranked
WHERE best_rank <= 3 OR worst_rank <= 3
ORDER BY eco_family, white_score DESC;


-- =============================================================================
-- SECTION 3. PLAYER LEADERBOARD
-- Skills: UNION ALL to reshape one-row-per-game into one-row-per-player-game
-- NOTE: names are not standardised in the source ("Gupta, Abhijeet" vs
--       "Abhijeet Gupta"), so one person can appear under two spellings.
-- =============================================================================

WITH player_games AS (
    SELECT white AS player, white_score       AS score, white_elo AS own_elo, black_elo AS opp_elo, 'White' AS colour FROM games_clean
    UNION ALL
    SELECT black,           1 - white_score,            black_elo,            white_elo,            'Black'          FROM games_clean
)
SELECT
    player,
    count(*)                                        AS games,
    round(sum(score)::numeric, 1)                   AS points,
    round(100.0 * avg(score), 1)                    AS score_pct,
    round(avg(opp_elo))                             AS avg_opp_elo,
    max(own_elo)                                    AS peak_elo
FROM player_games
GROUP BY player
HAVING count(*) >= 20
ORDER BY games DESC
LIMIT 25;

-- 3b. Does colour matter? White's advantage overall and by rating tier
SELECT
    CASE
        WHEN (white_elo + black_elo) / 2.0 >= 2500 THEN '2500+'
        WHEN (white_elo + black_elo) / 2.0 >= 2200 THEN '2200-2499'
        WHEN (white_elo + black_elo) / 2.0 >= 1800 THEN '1800-2199'
        ELSE 'under 1800'
    END                                             AS avg_rating_tier,
    count(*)                                        AS games,
    round(100.0 * avg(white_score), 1)              AS white_score_pct
FROM games_clean
WHERE white_elo IS NOT NULL AND black_elo IS NOT NULL
GROUP BY 1
ORDER BY min((white_elo + black_elo) / 2.0) DESC;


-- =============================================================================
-- SECTION 4. DO HIGHER-RATED PLAYERS WIN MORE? (ACTUAL VS EXPECTED)
-- Skills: bucketing, Elo expected-score formula, comparing model vs reality
-- Expected score for White = 1 / (1 + 10 ^ (-(white_elo - black_elo) / 400))
-- =============================================================================

SELECT
    floor(elo_diff / 100.0) * 100                             AS elo_gap_bucket,   -- White minus Black
    count(*)                                                  AS games,
    round(100.0 * avg(white_score), 1)                        AS actual_white_pct,
    round(100.0 * avg(1 / (1 + power(10, -elo_diff / 400.0))), 1) AS expected_white_pct,
    round(100.0 * avg(white_score)
        - 100.0 * avg(1 / (1 + power(10, -elo_diff / 400.0))), 1) AS over_under_expected,
    round(100.0 * avg((result = '1/2-1/2')::int), 1)          AS draw_pct
FROM games_clean
WHERE white_elo IS NOT NULL AND black_elo IS NOT NULL
GROUP BY 1
HAVING count(*) >= 50
ORDER BY 1;

-- 4b. Do draws become more common at higher rating levels?
SELECT
    floor(((white_elo + black_elo) / 2.0) / 200) * 200        AS avg_rating_band,
    count(*)                                                  AS games,
    round(100.0 * avg((result = '1/2-1/2')::int), 1)          AS draw_pct
FROM games_clean
WHERE white_elo IS NOT NULL AND black_elo IS NOT NULL
GROUP BY 1
HAVING count(*) >= 100
ORDER BY 1;

-- 4c. Biggest upsets: lower-rated player wins against a 300+ Elo gap
SELECT
    game_id, lichess_id, date, white, black, white_elo, black_elo,
    elo_diff, result, opening
FROM games_clean
WHERE (result = '1-0' AND elo_diff <= -300)
   OR (result = '0-1' AND elo_diff >=  300)
ORDER BY abs(elo_diff) DESC
LIMIT 15;


-- =============================================================================
-- SECTION 5. GAME LENGTH BY OPENING
-- Skills: percentile_cont (ordered-set aggregate), median vs mean
-- num_plies counts half-moves; divide by 2 for full moves.
-- =============================================================================

SELECT
    opening,
    count(*)                                                                   AS games,
    round(avg(num_plies) / 2.0, 1)                                             AS mean_moves,
    round((percentile_cont(0.5) WITHIN GROUP (ORDER BY num_plies) / 2.0)::numeric, 1) AS median_moves,
    min(num_plies) / 2                                                         AS shortest,
    max(num_plies) / 2                                                         AS longest
FROM games_clean
GROUP BY opening
HAVING count(*) >= 40
ORDER BY median_moves DESC
LIMIT 15;

-- 5b. Length distribution: how many games end in each move range?
SELECT
    CASE
        WHEN num_plies <  40 THEN '1. under 20 moves'
        WHEN num_plies <  80 THEN '2. 20-39 moves'
        WHEN num_plies < 120 THEN '3. 40-59 moves'
        ELSE                      '4. 60+ moves'
    END                                              AS game_length,
    count(*)                                         AS games,
    round(100.0 * avg((result = '1/2-1/2')::int), 1) AS draw_pct
FROM games_clean
GROUP BY 1
ORDER BY 1;


-- =============================================================================
-- SECTION 6. MONTHLY TRENDS
-- Skills: date_trunc, LAG(), running totals with SUM() OVER
-- =============================================================================

WITH monthly AS (
    SELECT
        date_trunc('month', date)::date                       AS month,
        count(*)                                              AS games,
        round(avg((white_elo + black_elo) / 2.0))             AS avg_rating,
        round(100.0 * avg(white_score), 1)                    AS white_score_pct,
        round(100.0 * avg((result = '1/2-1/2')::int), 1)      AS draw_pct
    FROM games_clean
    GROUP BY 1
)
SELECT
    month,
    games,
    games - lag(games) OVER (ORDER BY month)                  AS change_vs_prev_month,
    sum(games) OVER (ORDER BY month)                          AS running_total,
    avg_rating,
    white_score_pct,
    draw_pct
FROM monthly
ORDER BY month;

-- 6b. Most popular opening in each month (rank within month)
WITH monthly_openings AS (
    SELECT date_trunc('month', date)::date AS month, opening, count(*) AS games
    FROM games_clean
    GROUP BY 1, 2
),
ranked AS (
    SELECT *, rank() OVER (PARTITION BY month ORDER BY games DESC) AS rnk
    FROM monthly_openings
)
SELECT month, opening, games
FROM ranked
WHERE rnk = 1
ORDER BY month;


-- =============================================================================
-- SECTION 7. INDEXING AND QUERY PERFORMANCE
-- Skills: CREATE INDEX, EXPLAIN ANALYZE, comparing plans
-- Compare "Execution Time" in the two plans. On ~40k rows the gain is small;
-- the point is to show the plan changing from Seq Scan to an Index/Bitmap Scan.
-- =============================================================================

-- Make sure we are measuring from a clean state
DROP INDEX IF EXISTS idx_games_eco;
DROP INDEX IF EXISTS idx_games_date;

-- 7a. BEFORE: no index on eco (expect "Seq Scan on games")
EXPLAIN (ANALYZE, BUFFERS)
SELECT eco, count(*) AS games, avg(CASE result WHEN '1-0' THEN 1 WHEN '0-1' THEN 0 ELSE 0.5 END) AS white_score
FROM games
WHERE eco = 'B90' AND variant = 'Standard'
GROUP BY eco;

-- 7b. Create indexes on the columns the analyses filter and group by
CREATE INDEX idx_games_eco  ON games (eco);
CREATE INDEX idx_games_date ON games (date);
ANALYZE games;     -- refresh planner statistics

-- 7c. AFTER: same query (expect "Index Scan" or "Bitmap Index Scan")
EXPLAIN (ANALYZE, BUFFERS)
SELECT eco, count(*) AS games, avg(CASE result WHEN '1-0' THEN 1 WHEN '0-1' THEN 0 ELSE 0.5 END) AS white_score
FROM games
WHERE eco = 'B90' AND variant = 'Standard'
GROUP BY eco;

-- 7d. Same idea for a date-range query
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) FROM games WHERE date BETWEEN '2026-07-01' AND '2026-07-07';

-- =============================================================================
-- END
-- =============================================================================
