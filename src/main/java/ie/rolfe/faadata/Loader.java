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

import java.io.BufferedOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.URI;
import java.net.URISyntaxException;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.file.FileVisitOption;
import java.nio.file.Files;
import java.nio.file.Path;
import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.Statement;
import java.time.Duration;
import java.util.ArrayList;
import java.util.List;
import java.util.UUID;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.TimeUnit;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import java.util.stream.Collectors;
import java.util.stream.Stream;
import java.util.zip.Deflater;
import java.util.zip.GZIPInputStream;
import java.util.zip.GZIPOutputStream;
import java.util.zip.ZipEntry;
import java.util.zip.ZipInputStream;

import ie.rolfe.faadata.CsvConverter.TableColumn;

/**
 * Command-line entry point.
 *
 * <pre>
 *   ping                          check connectivity and print the warehouse's version
 *   schema &lt;file.sql&gt;...          run ';'-separated SQL statements
 *   load &lt;table&gt; [--replace | --replace-where PREDICATE] [--combine] [--jobs N] &lt;path&gt;...
 *                                 load CSV files (plain, .gz or .zip) into a table
 *   bench &lt;workload&gt; [options]     time randomly generated queries (see {@link QueryBench})
 * </pre>
 *
 * A load converts each file to gzipped CSV in the table's column order (see
 * {@link CsvConverter}) and uploads it to a new directory in the staging
 * volume, --jobs N files at a time. One INSERT then reads them all with
 * {@code read_files}, so the table changes once, atomically, however many
 * files there are, and the staged files are deleted. --combine uploads all the
 * files under each path as one file, which is much faster for many small files.
 * <p>
 * By default the rows are appended. --replace replaces the whole table
 * (INSERT OVERWRITE). --replace-where replaces the rows matching PREDICATE
 * (INSERT ... REPLACE WHERE), and the INSERT fails if a new row doesn't match
 * it: that is how a month of flights is reloaded.
 */
public class Loader {

    public static void main(String[] args) throws Exception {
        if (args.length == 0) {
            usage();
            return;
        }
        try {
            run(args);
        } catch (SQLException e) {
            System.err.println("error: " + serverMessage(e));
            System.exit(1);
        } catch (IllegalArgumentException | IllegalStateException e) {
            System.err.println("error: " + e.getMessage());
            System.exit(1);
        }
    }

    /**
     * The useful part of a driver exception: its message embeds the server's
     * whole response, Java stack trace and all, with the error in displayMessage.
     */
    static String serverMessage(SQLException e) {
        String m = String.valueOf(e.getMessage());
        int start = m.indexOf("displayMessage:");
        if (start >= 0) {
            int end = m.indexOf(", diagnosticInfo:", start);
            return m.substring(start + "displayMessage:".length(), end > start ? end : m.length()).strip();
        }
        return m;
    }

    private static void run(String[] args) throws Exception {
        DatabricksConfig config = DatabricksConfig.load();
        if (args[0].equals("bench")) {
            QueryBench.run(config, List.of(args).subList(1, args.length));
            return;
        }
        try (Connection connection = config.newConnection()) {
            switch (args[0]) {
                case "ping" -> ping(connection, config);
                case "schema" -> schema(connection, List.of(args).subList(1, args.length));
                case "load" -> {
                    if (args.length < 3) {
                        usage();
                        System.exit(1);
                    }
                    load(connection, config, args[1], List.of(args).subList(2, args.length));
                }
                default -> {
                    usage();
                    System.exit(1);
                }
            }
        }
    }

    private static void usage() {
        System.err.println("usage: Loader ping | schema <file.sql>... | load <table> [--replace | --replace-where PREDICATE] [--combine] [--jobs N] <file-or-dir>...\n"
                + "     | bench flight-history [--rate Q] [--threads N] [--duration S] [--timeout S] [--seed N] [--log file.csv]");
    }

    private static void ping(Connection connection, DatabricksConfig config) throws Exception {
        try (Statement st = connection.createStatement();
             ResultSet rs = st.executeQuery("SELECT current_version().dbsql_version, current_user(), current_catalog()")) {
            rs.next();
            System.out.println("Connected to " + config.host() + ", warehouse " + config.warehouseId() + " as "
                    + rs.getString(2) + ", Databricks SQL " + rs.getString(1) + ", catalog " + rs.getString(3));
        }
    }

    private static void schema(Connection connection, List<String> files) throws Exception {
        for (String file : files) {
            for (String stmt : Files.readString(Path.of(file)).split(";")) {
                String sql = stripComments(stmt).strip();
                if (!sql.isEmpty()) {
                    System.out.println("Executing: " + sql.lines().findFirst().orElse(""));
                    try (Statement st = connection.createStatement()) {
                        st.execute(sql);
                    }
                }
            }
        }
    }

    private static String stripComments(String sql) {
        return sql.lines().filter(l -> !l.strip().startsWith("--")).reduce("", (a, b) -> a + b + "\n");
    }

    private static void load(Connection connection, DatabricksConfig config, String table, List<String> args)
            throws Exception {
        List<String> paths = new ArrayList<>();
        String insert = "INSERT INTO";
        String where = "";
        boolean combine = false;
        int jobs = 1;
        for (int i = 0; i < args.size(); i++) {
            switch (args.get(i)) {
                case "--replace" -> insert = "INSERT OVERWRITE";
                case "--replace-where" -> where = " REPLACE WHERE " + args.get(++i);
                case "--combine" -> combine = true;
                case "--jobs" -> jobs = Integer.parseInt(args.get(++i));
                default -> paths.add(args.get(i));
            }
        }
        if (!where.isEmpty() && !insert.equals("INSERT INTO")) {
            throw new IllegalArgumentException("--replace and --replace-where can't be used together");
        }
        List<TableColumn> schema = columns(connection, table);

        // One staged file per input file, or per path with --combine.
        List<List<Path>> batches = new ArrayList<>();
        if (combine) {
            for (String path : paths) {
                batches.add(expand(List.of(path)));
            }
        } else {
            for (Path file : expand(paths)) {
                batches.add(List.of(file));
            }
        }
        if (batches.stream().allMatch(List::isEmpty)) {
            throw new IllegalArgumentException("no files to load in " + paths);
        }

        Volume volume = new Volume(config);
        String dir = config.volumePath() + "/load/" + table.replace('.', '_') + "_" + UUID.randomUUID();
        volume.mkdirs(dir);
        long start = System.nanoTime();
        long totalRows = 0;
        ExecutorService pool = Executors.newFixedThreadPool(jobs);
        // Ctrl-C or kill skips the finally block below, so the staged files are
        // also deleted on the way out, once the uploads have stopped.
        Thread cleanup = new Thread(() -> {
            pool.shutdownNow();
            try {
                pool.awaitTermination(30, TimeUnit.SECONDS);
            } catch (InterruptedException e) {
                // deleting anyway
            }
            deleteStaged(volume, dir);
        });
        Runtime.getRuntime().addShutdownHook(cleanup);
        try {
            List<Future<Long>> results = new ArrayList<>();
            for (int b = 0; b < batches.size(); b++) {
                List<Path> files = batches.get(b);
                if (files.isEmpty()) {
                    continue;
                }
                String target = dir + String.format("/%05d.csv.gz", b);
                results.add(pool.submit(() -> {
                    long t0 = System.nanoTime();
                    long rows = stage(volume, schema, files, target);
                    System.out.printf("%s: %,d rows staged in %.1fs%n",
                            files.size() == 1 ? files.get(0) : files.get(0).getParent() + " (" + files.size() + " files)",
                            rows, (System.nanoTime() - t0) / 1e9);
                    return rows;
                }));
            }
            for (Future<Long> result : results) {
                try {
                    totalRows += result.get();
                } catch (ExecutionException e) {
                    throw e.getCause() instanceof Exception cause ? cause : e;
                }
            }
            pool.shutdown();

            long t0 = System.nanoTime();
            String sql = insert + " " + table + where + "\nSELECT "
                    + schema.stream().map(c -> quoteName(c.name())).collect(Collectors.joining(", "))
                    + "\nFROM " + readFiles(dir, schema);
            try (Statement st = connection.createStatement()) {
                st.execute(sql);
            }
            System.out.printf("%s: %,d rows in %.1fs (%.1fs for the INSERT)%n", table, totalRows,
                    (System.nanoTime() - start) / 1e9, (System.nanoTime() - t0) / 1e9);
        } finally {
            pool.shutdownNow();
            try {
                Runtime.getRuntime().removeShutdownHook(cleanup);
            } catch (IllegalStateException e) {
                return;   // shutting down: the hook is deleting them
            }
            deleteStaged(volume, dir);
        }
    }

    /** Deletes the staged files, and their directory. */
    private static void deleteStaged(Volume volume, String dir) {
        try {
            for (String file : volume.list(dir)) {
                volume.deleteQuietly(file);
            }
        } catch (Exception e) {
            System.err.println("warn: cannot list " + dir + ": " + e.getMessage());
        }
        volume.deleteDirectoryQuietly(dir);
    }

    /** The table's columns, in order. {@code table} is schema.table, in the connection's catalog. */
    private static List<TableColumn> columns(Connection connection, String table) throws Exception {
        String[] parts = table.split("\\.");
        if (parts.length != 2) {
            throw new IllegalArgumentException("table must be schema.table, e.g. faa.ontime, not " + table);
        }
        List<TableColumn> columns = new ArrayList<>();
        try (PreparedStatement ps = connection.prepareStatement(
                "SELECT column_name, data_type, is_nullable FROM information_schema.columns"
                        + " WHERE table_schema = ? AND table_name = ? ORDER BY ordinal_position")) {
            ps.setString(1, parts[0].toLowerCase());
            ps.setString(2, parts[1].toLowerCase());
            try (ResultSet rs = ps.executeQuery()) {
                while (rs.next()) {
                    columns.add(new TableColumn(rs.getString(1), rs.getString(2), "YES".equals(rs.getString(3))));
                }
            }
        }
        if (columns.isEmpty()) {
            throw new IllegalArgumentException("table " + table + " not found in catalog " + connection.getCatalog());
        }
        return columns;
    }

    /**
     * The read_files call for the staged files in {@code dir}: CSV as {@link
     * CsvConverter} writes it, read strictly, so that a field that doesn't
     * parse fails the load instead of becoming NULL.
     */
    static String readFiles(String dir, List<TableColumn> schema) {
        String columns = schema.stream().map(c -> quoteName(c.name()) + " " + c.type()).collect(Collectors.joining(", "));
        return "read_files(" + sqlString(dir + "/")
                + ", format => 'csv', header => false, schema => " + sqlString(columns)
                + ", nullValue => " + sqlString(CsvConverter.NULL_MARKER)
                + ", emptyValue => '', quote => '\"', escape => '\"', mode => 'FAILFAST')";
    }

    static String quoteName(String name) {
        return "`" + name.replace("`", "``") + "`";
    }

    /** A SQL string literal; raw (r'...'), so backslashes are literal. */
    static String sqlString(String s) {
        if (s.contains("'")) {
            throw new IllegalArgumentException("unexpected quote in " + s);
        }
        return "r'" + s + "'";
    }

    /** Converts {@code files} into one gzipped CSV, uploads it as {@code target}, and returns its rows. */
    private static long stage(Volume volume, List<TableColumn> schema, List<Path> files, String target)
            throws IOException, InterruptedException {
        Path tmp = Files.createTempFile("faa-load-", ".csv.gz");
        try {
            long rows = 0;
            // The fastest level shrinks the upload about sixfold for much less
            // CPU than parsing takes. The converter writes a few bytes at a
            // time, so it needs a buffer in front of the compressor: without
            // one, a month of flights takes 57 s to write instead of 4.
            try (OutputStream file = Files.newOutputStream(tmp);
                 OutputStream gz = new BufferedOutputStream(new GZIPOutputStream(file, 1 << 16) {
                     {
                         def.setLevel(Deflater.BEST_SPEED);
                     }
                 }, 1 << 16)) {
                for (Path f : files) {
                    try (InputStream in = open(f)) {
                        CsvConverter.CsvReader csv = new CsvConverter.CsvReader(in);
                        rows += new CsvConverter(CsvConverter.readHeader(csv), schema).write(csv, gz);
                    } catch (IOException | RuntimeException e) {
                        throw new IOException(f + ": " + e.getMessage(), e);
                    }
                }
            }
            volume.upload(tmp, target);
            return rows;
        } finally {
            Files.deleteIfExists(tmp);
        }
    }

    /** A CSV file's contents: plain, gzipped, or the first .csv inside a zip (as BTS publishes them). */
    private static InputStream open(Path file) throws IOException {
        String name = file.getFileName().toString().toLowerCase();
        InputStream raw = Files.newInputStream(file);
        if (name.endsWith(".gz")) {
            return new GZIPInputStream(raw, 1 << 16);
        }
        if (name.endsWith(".zip")) {
            ZipInputStream zip = new ZipInputStream(raw);
            ZipEntry entry;
            while ((entry = zip.getNextEntry()) != null) {
                if (!entry.isDirectory() && entry.getName().toLowerCase().endsWith(".csv")) {
                    return zip;
                }
            }
            zip.close();
            throw new IOException(file + " has no .csv inside");
        }
        return raw;
    }

    /** The files under {@code paths}, following symbolic links, so data/raw can link to another copy. */
    private static List<Path> expand(List<String> paths) throws IOException {
        List<Path> files = new ArrayList<>();
        for (String p : paths) {
            Path path = Path.of(p);
            if (Files.isDirectory(path)) {
                try (Stream<Path> s = Files.walk(path, FileVisitOption.FOLLOW_LINKS)) {
                    s.filter(Files::isRegularFile)
                            .filter(f -> !f.getFileName().toString().startsWith("."))
                            .sorted()
                            .forEach(files::add);
                }
            } else {
                files.add(path);
            }
        }
        return files;
    }

    /** Files in a Unity Catalog volume, through the Files REST API. */
    static final class Volume {
        private static final int ATTEMPTS = 4;

        private final DatabricksConfig config;
        private final HttpClient http = HttpClient.newBuilder().connectTimeout(Duration.ofSeconds(30)).build();

        Volume(DatabricksConfig config) {
            this.config = config;
        }

        void mkdirs(String dir) throws IOException, InterruptedException {
            send(request("/api/2.0/fs/directories", dir, null).PUT(HttpRequest.BodyPublishers.noBody()), "create " + dir);
        }

        void upload(Path local, String remote) throws IOException, InterruptedException {
            send(request("/api/2.0/fs/files", remote, "overwrite=true")
                    .header("Content-Type", "application/octet-stream")
                    .PUT(HttpRequest.BodyPublishers.ofFile(local)), "upload " + remote);
        }

        /** The paths of the files in {@code dir}. */
        List<String> list(String dir) throws IOException, InterruptedException {
            String json = send(request("/api/2.0/fs/directories", dir, null).GET(), "list " + dir);
            List<String> files = new ArrayList<>();
            // {"contents": [{"path": "/Volumes/...", "is_directory": false, ...}, ...]}
            Matcher m = Pattern.compile("\"path\"\\s*:\\s*\"([^\"]+)\"[^}]*\"is_directory\"\\s*:\\s*false").matcher(json);
            while (m.find()) {
                files.add(m.group(1));
            }
            return files;
        }

        void deleteQuietly(String remote) {
            try {
                send(request("/api/2.0/fs/files", remote, null).DELETE(), "delete " + remote);
            } catch (Exception e) {
                System.err.println("warn: " + e.getMessage());
            }
        }

        void deleteDirectoryQuietly(String dir) {
            try {
                send(request("/api/2.0/fs/directories", dir, null).DELETE(), "delete " + dir);
            } catch (Exception e) {
                System.err.println("warn: " + e.getMessage());
            }
        }

        private HttpRequest.Builder request(String api, String path, String query) {
            try {
                return HttpRequest.newBuilder(new URI("https", config.host(), api + path, query, null))
                        .header("Authorization", "Bearer " + config.token())
                        .timeout(Duration.ofMinutes(30));
            } catch (URISyntaxException e) {
                throw new IllegalArgumentException(path, e);
            }
        }

        /** Sends the request, retrying on server errors and lost connections; returns the response body. */
        private String send(HttpRequest.Builder builder, String what) throws IOException, InterruptedException {
            HttpRequest request = builder.build();
            for (int attempt = 1; ; attempt++) {
                String problem;
                try {
                    HttpResponse<String> response = http.send(request, HttpResponse.BodyHandlers.ofString());
                    int status = response.statusCode();
                    if (status / 100 == 2) {
                        return response.body();
                    }
                    problem = "HTTP " + status + ": " + response.body();
                    if (status < 500 && status != 429) {
                        throw new IOException("cannot " + what + ": " + problem);
                    }
                } catch (IOException e) {
                    if (e.getMessage() != null && e.getMessage().startsWith("cannot ")) {
                        throw e;
                    }
                    problem = e.toString();
                }
                if (attempt == ATTEMPTS) {
                    throw new IOException("cannot " + what + " after " + ATTEMPTS + " attempts: " + problem);
                }
                System.err.println("warn: " + what + ": " + problem + "; retrying");
                Thread.sleep(2000L << attempt);
            }
        }
    }
}
