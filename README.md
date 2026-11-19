# Chess Game Analysis with PostgreSQL

SQL analysis of **40,038 Lichess games** (January to July 2026): data cleaning, opening statistics, player performance, rating-vs-result analysis, and query tuning, all in PostgreSQL. The results are presented in a one-page dashboard.

**Live dashboard: https://cloudbv.github.io/sql-chess-analysis/**

I built this as the analysis side of my chess project. [ChessAutoplay](https://play.google.com/store/apps/details?id=com.cloudbv.chesstournamentautoplay) (Android, Godot 4) and my Python PGN tool prepare the data; this repo asks questions of it with SQL.

## Dashboard

`index.html` is a single static page (no build step, no dependencies) that charts the query results exported from `chess_analysis.sql`. It shows:

- Draw rate by rating band
- Actual vs Elo-expected White score by rating gap
- Result split and White's score by rating tier
- Draw rate by game length
- Best and worst openings for White
- The biggest upsets

It follows your light or dark mode and works on mobile.

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

| Section | Question | SQL techniques | Dashboard chart |
|---|---|---|---|
| 1 | How clean is the data? | `FILTER`, `CASE`, views, `NULL` handling | KPI strip, result split |
| 2 | Which openings score best for White in each ECO family? | CTEs, `RANK() OVER (PARTITION BY ...)` | Best and worst openings |
| 3 | Who played the most, and how did they score? Does colour matter? | `UNION ALL` reshaping, `HAVING` | White's score by rating tier |
| 4 | Do higher-rated players win as often as Elo predicts? | bucketing, expected-score formula | Actual vs expected, draw rate by rating, biggest upsets |
| 5 | Which openings lead to the longest games? | `percentile_cont` (median) | Draw rate by game length |
| 6 | How do volume, rating, and draw rate change by month? | `date_trunc`, `LAG()`, running `SUM() OVER` | not charted (see Limitations) |
| 7 | Does indexing speed up the queries? | `CREATE INDEX`, `EXPLAIN ANALYZE` | not charted |

The player leaderboard (Section 3) is left out of the dashboard because it lists individual people and the names are not standardised.

## Selected findings

- **Draw rate rises steeply with rating:** 16.4% for average rating around 1400, 24.8% around 2000, 39.9% around 2400, and 46.0% at 2600+ (363 games).
- **White scores about 53 to 54%** across rating tiers (based on 36,518 cleaned games).
- **Elo expectation vs reality:** the standard Elo formula has no notion of colour. Comparing actual to expected White scores, White outperforms the formula when it is the lower-rated side (about +7 points at gaps of 200 to 400) and slightly underperforms it when it is the higher-rated side. This pattern is consistent with a built-in advantage for White.
- **Very short and very long games draw most:** 41.2% of games under 20 moves end in a draw, against about 20% for games of 20 to 59 moves and 28.6% for games of 60+ moves.
- **Indexing:** an ECO filter query changed from a sequential scan to a bitmap index scan after `CREATE INDEX`. The dataset is small, so the absolute gain is modest; the point is the changed query plan.

## How to run

1. Create a database and run **Section 0** of `chess_analysis.sql` to create the `games` table.
2. Load your data. In pgAdmin: right-click the table, then *Import/Export Data*, with format `csv`, delimiter `\t`, header on, encoding `UTF8`. Or in psql:
   ```
   \copy games FROM 'games_export.txt' WITH (FORMAT csv, DELIMITER E'\t', HEADER true, ENCODING 'UTF8')
   ```
3. Run the rest of the script in order. It is re-runnable.
4. To view the dashboard locally, open `index.html` in a browser. The numbers are embedded in the page, so no server is needed.

## Limitations

- About 98% of the cleaned games (35,880 of 36,518) were played in July 2026, so the monthly trend query (Section 6) runs but does not show a meaningful trend, and the dashboard leaves it out.
- Player names are not standardised in the source (for example, `Gupta, Abhijeet` and `Abhijeet Gupta` can both appear), so the player leaderboard can split one person across two spellings.
- Games come from a mix of tournaments; rating pools and time controls vary (about half of games have no time control recorded).
- Opening statistics use a minimum of 30 games per opening, so each percentage still rests on a modest sample.
- Section 7 timings depend on hardware and data size.

## Tools

PostgreSQL 16, pgAdmin 4. Data preparation: Python, python-chess. Dashboard: plain HTML, CSS, and JavaScript with inline SVG charts.

---

Built by [Yosef Setiawan](https://github.com/cloudBV)
