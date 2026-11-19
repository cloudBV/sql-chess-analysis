# Chess Game Analysis with PostgreSQL

SQL analysis of **40,038 Lichess games** (January to July 2026): data cleaning, opening statistics, player performance, rating-vs-result analysis, and query tuning, all in PostgreSQL.

I built this as the analysis side of my chess project. [ChessAutoplay](https://play.google.com/store/apps/details?id=) (Android, Godot 4) and my Python PGN tool prepare the data; this repo asks questions of it with SQL.

## Dataset

- 40,038 games, 16 columns: players, Elo, ECO code, opening name, result, time control, termination, move count, and full movetext
- Tab-separated export from Lichess PGN data (open data; attribution as in ChessAutoplay)
- The raw file (about 25 MB) is not committed. See "How to run" below.

## Data quality issues found and handled

Before any analysis, the `games_clean` view fixes problems in the raw data. Raw count: 40,038 games, **clean count: 36,518**.

| Issue | Games affected | Handling |
|---|---|---|
| Unfinished / unknown result (`*`) | 2,256 | excluded |
| Chess960 variant (different opening theory) | 571 | excluded |
| Games marked `Unplayed` | 397 | excluded |
| Chess engine games (TCEC, Elo up to 3,552) | 300 | excluded, since the analysis is about human players |
| Elo stored as `0` (placeholder for unrated) | 976 | converted to `NULL` |
| Malformed draw label `0.5-0.5` | 1 | normalised to `1/2-1/2` |

One bug caught during testing: a filter written as `NOT (... OR white_elo > 3000)` silently dropped every row with a `NULL` Elo, because `NULL` propagates through `NOT`. Fixed with `coalesce`.

## What the analysis covers

| Section | Question | SQL techniques |
|---|---|---|
| 1 | How clean is the data? | `FILTER`, `CASE`, views, `NULL` handling |
| 2 | Which openings score best for White in each ECO family? | CTEs, `RANK() OVER (PARTITION BY ...)` |
| 3 | Who played the most, and how did they score? Does colour matter? | `UNION ALL` reshaping, `HAVING` |
| 4 | Do higher-rated players win as often as Elo predicts? | bucketing, expected-score formula |
| 5 | Which openings lead to the longest games? | `percentile_cont` (median) |
| 6 | How do volume, rating, and draw rate change by month? | `date_trunc`, `LAG()`, running `SUM() OVER` |
| 7 | Does indexing speed up the queries? | `CREATE INDEX`, `EXPLAIN ANALYZE` |

## Selected findings

- **Draw rate rises steeply with rating:** 16.4% for average rating around 1400, 24.8% around 2000, 39.9% around 2400, and 46.0% at 2600+ (363 games).
- **White scores about 53 to 54%** across rating tiers (based on 36,518 cleaned games).
- **Elo expectation vs reality:** the standard Elo formula has no notion of colour. Comparing actual to expected White scores, White outperforms the formula when it is the lower-rated side (about +7 points at gaps of 200 to 400) and slightly underperforms it when it is the higher-rated side. This pattern is consistent with a built-in advantage for White.
- **Indexing:** an ECO filter query changed from a sequential scan to a bitmap index scan after `CREATE INDEX`: `[your ms before]` to `[your ms after]`. The dataset is small, so the absolute gain is modest; the point is the changed query plan.

## How to run

1. Create a database and run **Section 0** of `chess_analysis.sql` to create the `games` table.
2. Load your data. In pgAdmin: right-click the table, then *Import/Export Data*, with format `csv`, delimiter `\t`, header on, encoding `UTF8`. Or in psql:
   ```
   \copy games FROM 'games_export.txt' WITH (FORMAT csv, DELIMITER E'\t', HEADER true, ENCODING 'UTF8')
   ```
3. Run the rest of the script in order. It is re-runnable.

## Limitations

- Player names are not standardised in the source (for example, `Gupta, Abhijeet` and `Abhijeet Gupta` can both appear), so the player leaderboard can split one person across two spellings.
- Games come from a mix of tournaments; rating pools and time controls vary (about half of games have no time control recorded).
- Section 7 timings depend on hardware and data size.

## Tools

PostgreSQL 16, pgAdmin 4. Data preparation: Python, python-chess.

---

Built by [Yosef Setiawan](https://github.com/cloudBV)
