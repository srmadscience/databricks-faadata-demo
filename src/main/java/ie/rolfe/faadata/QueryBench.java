/*
 * Copyright 2026 David Rolfe
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

package ie.rolfe.faadata;

import java.io.IOException;
import java.io.PrintWriter;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardOpenOption;
import java.sql.Connection;
import java.sql.Date;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.Statement;
import java.time.LocalDate;
import java.time.ZonedDateTime;
import java.time.format.DateTimeFormatter;
import java.time.temporal.ChronoUnit;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Random;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.LinkedBlockingQueue;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.locks.LockSupport;

/**
 * Query performance test: issues randomly generated queries asynchronously and
 * times each one until its last row has been read.
 *
 * <pre>
 *   bench &lt;workload&gt; [--rate Q] [--threads N] [--duration S] [--timeout S] [--seed N]
 *                    [--log file.csv] [--results file.csv --commit C --comment TEXT]
 * </pre>
 *
 * With --rate, queries are started at Q a second whatever happens to earlier
 * ones (an open loop), on up to N threads. A query's latency runs from when it
 * was due to start, so time spent waiting for a free thread counts: when the
 * server falls behind, latencies grow rather than the rate quietly dropping.
 * Without --rate, N threads each issue queries back to back, which measures the
 * most the SQL warehouse can do for one client. A query still running after
 * --timeout seconds (default 60) is cancelled and counts as an error. --log
 * writes one line per query; --results appends a summary line to the test
 * results file.
 * <p>
 * Each thread has its own JDBC connection, with the result cache off
 * ({@code use_cached_result = false}), so every query really runs.
 */
public final class QueryBench {

    /** One query to run, and how to describe it in the log. */
    record Query(String sql, List<Object> params, String description, long days) {
    }

    /** A workload makes random queries; it may read what it needs from the server first. */
    interface Workload {
        Query next(Random random);
    }

    /** Makes a workload, reading what it needs over the connection. */
    interface WorkloadFactory {
        Workload create(Connection connection) throws SQLException;
    }

    private static final Map<String, WorkloadFactory> WORKLOADS = Map.of(
            "flight-history", FlightHistory::new);

    /**
     * Every flight of one aircraft, picked at random from all those with
     * flights, between two random dates from 1 day to 10 years apart. Range
     * lengths are spread evenly on a log scale, so days, weeks, months and
     * years are equally likely. faa.ontime is clustered by tail and date, so
     * the warehouse skips the files that hold none of that aircraft's flights.
     */
    static final class FlightHistory implements Workload {
        static final int MAX_DAYS = 3653;
        private static final String SQL = """
                SELECT FlightDate, Reporting_Airline, Flight_Number_Reporting_Airline,
                       Origin, Dest, CRSDepTime, DepTime, DepDelay, CRSArrTime, ArrTime, ArrDelay,
                       Cancelled, CancellationCode, Diverted, Distance
                FROM faa.ontime
                WHERE tail = ? AND FlightDate BETWEEN ? AND ?
                ORDER BY FlightDate, CRSDepTime""";

        private final List<String> tails;
        private final LocalDate first;
        private final LocalDate last;

        FlightHistory(Connection connection) throws SQLException {
            List<String> found = new ArrayList<>();
            try (Statement st = connection.createStatement()) {
                // Real registrations only: not the empty tail of unassigned flights,
                // nor placeholders such as '#N/A'.
                try (ResultSet rs = st.executeQuery(
                        "SELECT DISTINCT tail FROM faa.tail_day WHERE tail RLIKE '^N[0-9][0-9A-Z]*$' ORDER BY tail")) {
                    while (rs.next()) {
                        found.add(rs.getString(1));
                    }
                }
                if (found.isEmpty()) {
                    throw new IllegalStateException("faa.tail_day is empty: load flights and run build-tail-day.sh first");
                }
                try (ResultSet rs = st.executeQuery("SELECT min(FlightDate), max(FlightDate) FROM faa.tail_day")) {
                    rs.next();
                    first = rs.getDate(1).toLocalDate();
                    last = rs.getDate(2).toLocalDate();
                }
            }
            tails = found;
            System.out.printf("flight-history: %,d aircraft, flights %s to %s%n", tails.size(), first, last);
        }

        FlightHistory(List<String> tails, LocalDate first, LocalDate last) {
            this.tails = tails;
            this.first = first;
            this.last = last;
        }

        @Override
        public Query next(Random random) {
            String tail = tails.get(random.nextInt(tails.size()));
            long span = ChronoUnit.DAYS.between(first, last) + 1;
            long days = Math.min(span, Math.round(Math.exp(random.nextDouble() * Math.log(MAX_DAYS))));
            LocalDate from = first.plusDays((long) (random.nextDouble() * (span - days + 1)));
            LocalDate to = from.plusDays(days - 1);
            return new Query(SQL, List.of(tail, Date.valueOf(from), Date.valueOf(to)),
                    tail + "," + from + "," + to, days);
        }
    }

    /** What happened to one query. Times are in nanoseconds from the start of the test. */
    record Result(long due, long sent, long done, Query query, long rows, String error) {
        long latency() {
            return done - due;
        }

        long service() {
            return done - sent;
        }
    }

    public static void run(DatabricksConfig config, List<String> args) throws Exception {
        if (args.isEmpty() || !WORKLOADS.containsKey(args.get(0))) {
            throw new IllegalArgumentException("workload must be one of " + WORKLOADS.keySet());
        }
        String workloadName = args.get(0);
        double rate = 0;
        int threads = 8;
        int duration = 60;
        int timeout = 60;
        long seed = System.nanoTime();
        Path log = null;
        Path results = null;
        String commit = "";
        String comment = "";
        for (int i = 1; i < args.size(); i++) {
            String value = i + 1 < args.size() ? args.get(i + 1) : null;
            switch (args.get(i)) {
                case "--rate" -> rate = Double.parseDouble(value);
                case "--threads" -> threads = Integer.parseInt(value);
                case "--duration" -> duration = Integer.parseInt(value);
                case "--timeout" -> timeout = Integer.parseInt(value);
                case "--seed" -> seed = Long.parseLong(value);
                case "--log" -> log = Path.of(value);
                case "--results" -> results = Path.of(value);
                case "--commit" -> commit = value;
                case "--comment" -> comment = value;
                default -> throw new IllegalArgumentException("unknown option " + args.get(i));
            }
            i++;
        }

        try (Connections client = new Connections(config, threads, timeout)) {
            run(client, workloadName, rate, threads, duration, seed, log, results, commit, comment);
        }
    }

    /**
     * A JDBC connection for each thread, all opened at the start, so that no
     * timed query waits for one to open. A query takes one and gives it back.
     */
    static final class Connections implements AutoCloseable {
        private final List<Connection> all = Collections.synchronizedList(new ArrayList<>());
        private final LinkedBlockingQueue<Connection> idle = new LinkedBlockingQueue<>();
        private final int timeout;

        Connections(DatabricksConfig config, int count, int timeout) throws Exception {
            this.timeout = timeout;
            ExecutorService pool = Executors.newFixedThreadPool(Math.min(count, 16));
            try {
                List<Future<Connection>> opening = new ArrayList<>();
                for (int i = 0; i < count; i++) {
                    opening.add(pool.submit(() -> {
                        Connection c = config.newConnection();
                        all.add(c);
                        try (Statement st = c.createStatement()) {
                            st.execute("SET use_cached_result = false");
                        }
                        return c;
                    }));
                }
                for (Future<Connection> f : opening) {
                    try {
                        idle.add(f.get());
                    } catch (ExecutionException e) {
                        close();
                        throw e.getCause() instanceof Exception cause ? cause : e;
                    }
                }
            } finally {
                pool.shutdown();
            }
        }

        Connection take() throws InterruptedException {
            return idle.take();
        }

        void release(Connection c) {
            idle.add(c);
        }

        int timeout() {
            return timeout;
        }

        @Override
        public void close() {
            for (Connection c : all) {
                try {
                    c.close();
                } catch (SQLException e) {
                    // closing anyway
                }
            }
        }
    }

    private static void run(Connections client, String workloadName, double rate, int threads, int duration, long seed,
            Path log, Path results, String commit, String comment) throws Exception {
        Workload workload;
        String version;
        Connection c = client.take();
        try (Statement st = c.createStatement();
             ResultSet rs = st.executeQuery("SELECT current_version().dbsql_version")) {
            rs.next();
            version = "Databricks SQL " + rs.getString(1);
            workload = WORKLOADS.get(workloadName).create(c);
        } finally {
            client.release(c);
        }
        String runStart = ZonedDateTime.now().format(DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm:ssZ"));
        System.out.printf("%s for %d s, %s, %d threads, seed %d%n", workloadName, duration,
                rate > 0 ? rate + " queries/s" : "back to back", threads, seed);

        List<Result> done = rate > 0
                ? openLoop(client, workload, new Random(seed), rate, threads, duration)
                : closedLoop(client, workload, seed, threads, duration);
        done.sort((a, b) -> Long.compare(a.due(), b.due()));

        if (log != null) {
            writeLog(log, done);
        }
        String summary = summarise(done, duration);
        if (results != null) {
            boolean fresh = !Files.exists(results);
            try (PrintWriter out = new PrintWriter(Files.newBufferedWriter(results,
                    StandardOpenOption.CREATE, StandardOpenOption.APPEND))) {
                if (fresh) {
                    out.println("run_start,git_commit,server,workload,rate,threads,seconds,"
                            + "queries,errors,qps,p50_ms,p90_ms,p99_ms,max_ms,comment");
                }
                out.printf(Locale.ROOT, "%s,%s,%s,%s,%s,%d,%d,%s,%s%n", runStart, commit, version, workloadName,
                        rate > 0 ? fmt(rate) : "max", threads, duration, summary,
                        "\"" + comment.replace("\"", "\"\"") + "\"");
            }
        }
    }

    /** Starts queries at a fixed rate, each on the next free thread. */
    private static List<Result> openLoop(Connections client, Workload workload, Random random, double rate,
            int threads, int duration) throws InterruptedException {
        List<Result> done = Collections.synchronizedList(new ArrayList<>());
        ExecutorService pool = Executors.newFixedThreadPool(threads);
        long interval = (long) (1e9 / rate);
        long start = System.nanoTime();
        long end = start + duration * 1_000_000_000L;
        for (long due = start; due < end; due += interval) {
            long wait = due - System.nanoTime();
            if (wait > 0) {
                LockSupport.parkNanos(wait);
            }
            Query query = workload.next(random);
            long dueAt = due;
            pool.execute(() -> done.add(run(client, query, start, dueAt)));
        }
        pool.shutdown();
        if (!pool.awaitTermination(10, TimeUnit.MINUTES)) {
            System.err.println("warn: queries still running after 10 minutes; leaving them");
        }
        return new ArrayList<>(done);
    }

    /** Each thread issues queries back to back until the time is up. */
    private static List<Result> closedLoop(Connections client, Workload workload, long seed, int threads,
            int duration) throws InterruptedException {
        List<Result> done = Collections.synchronizedList(new ArrayList<>());
        long start = System.nanoTime();
        long end = start + duration * 1_000_000_000L;
        List<Thread> workers = new ArrayList<>();
        for (int t = 0; t < threads; t++) {
            Random random = new Random(seed + t);
            workers.add(Thread.ofPlatform().start(() -> {
                while (System.nanoTime() < end) {
                    done.add(run(client, workload.next(random), start, System.nanoTime()));
                }
            }));
        }
        for (Thread w : workers) {
            w.join();
        }
        return new ArrayList<>(done);
    }

    /** Runs one query, reading every row, and never throws. */
    private static Result run(Connections client, Query query, long start, long due) {
        long sent = System.nanoTime();
        long rows = 0;
        String error = null;
        Connection c = null;
        try {
            c = client.take();
            try (PreparedStatement ps = c.prepareStatement(query.sql())) {
                ps.setQueryTimeout(client.timeout());
                for (int i = 0; i < query.params().size(); i++) {
                    ps.setObject(i + 1, query.params().get(i));
                }
                try (ResultSet rs = ps.executeQuery()) {
                    while (rs.next()) {
                        rows++;
                    }
                }
            }
        } catch (Exception e) {
            error = String.valueOf(e.getMessage());
        } finally {
            if (c != null) {
                client.release(c);
            }
        }
        return new Result(due - start, sent - start, System.nanoTime() - start, query, rows, error);
    }

    private static void writeLog(Path log, List<Result> done) throws IOException {
        try (PrintWriter out = new PrintWriter(Files.newBufferedWriter(log))) {
            out.println("due_ms,latency_ms,service_ms,rows,days,tail,from,to,error");
            for (Result r : done) {
                out.printf(Locale.ROOT, "%.3f,%.3f,%.3f,%d,%d,%s,%s%n", r.due() / 1e6, r.latency() / 1e6,
                        r.service() / 1e6, r.rows(), r.query().days(), r.query().description(),
                        r.error() == null ? "" : "\"" + r.error().replace("\"", "\"\"").replace('\n', ' ') + "\"");
            }
        }
        System.out.println("Per-query log: " + log);
    }

    /**
     * Prints latency percentiles, overall and by length of date range, and
     * returns the CSV fields queries,errors,qps,p50_ms,p90_ms,p99_ms,max_ms.
     */
    private static String summarise(List<Result> done, int duration) {
        List<Result> ok = done.stream().filter(r -> r.error() == null).toList();
        long errors = done.size() - ok.size();
        done.stream().filter(r -> r.error() != null).limit(5)
                .forEach(r -> System.err.println("error: " + r.query().description().replace(',', ' ') + ": " + r.error()));
        System.out.printf("%n%,d queries, %,d errors, %.1f queries/s%n", done.size(), errors,
                ok.size() / (double) duration);
        System.out.printf("%-16s %7s %9s %9s %9s %9s %11s%n",
                "range", "queries", "p50 ms", "p90 ms", "p99 ms", "max ms", "rows/query");
        long[][] buckets = {{1, 7}, {8, 31}, {32, 365}, {366, Long.MAX_VALUE}};
        String[] names = {"1-7 days", "8-31 days", "1-12 months", "1-10 years"};
        for (int b = 0; b < buckets.length; b++) {
            long lo = buckets[b][0];
            long hi = buckets[b][1];
            printRow(names[b], ok.stream().filter(r -> r.query().days() >= lo && r.query().days() <= hi).toList());
        }
        double[] all = printRow("all", ok);
        System.out.println("Latency counts from when a query was due to start until its last row was read.");
        return String.format(Locale.ROOT, "%d,%d,%s,%s,%s,%s,%s", done.size(), errors,
                fmt(ok.size() / (double) duration), fmt(all[0]), fmt(all[1]), fmt(all[2]), fmt(all[3]));
    }

    /** Prints one row of the summary and returns its p50, p90, p99 and max in ms. */
    private static double[] printRow(String name, List<Result> results) {
        if (results.isEmpty()) {
            System.out.printf("%-16s %7d%n", name, 0);
            return new double[4];
        }
        long[] latency = results.stream().mapToLong(Result::latency).sorted().toArray();
        double[] p = {pct(latency, 50), pct(latency, 90), pct(latency, 99), latency[latency.length - 1] / 1e6};
        System.out.printf(Locale.ROOT, "%-16s %7d %9.1f %9.1f %9.1f %9.1f %11.0f%n", name, results.size(),
                p[0], p[1], p[2], p[3],
                results.stream().mapToLong(Result::rows).average().orElse(0));
        return p;
    }

    /** The nearest-rank percentile, in ms. */
    private static double pct(long[] sorted, double percentile) {
        int rank = (int) Math.ceil(percentile / 100 * sorted.length);
        return sorted[Math.max(0, rank - 1)] / 1e6;
    }

    private static String fmt(double v) {
        return String.format(Locale.ROOT, "%.1f", v);
    }

    private QueryBench() {
    }
}
