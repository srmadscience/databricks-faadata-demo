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
import java.io.InputStream;
import java.io.OutputStream;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.function.UnaryOperator;

/**
 * Rewrites CSV with a header line as headerless CSV whose fields are exactly
 * the table's columns, in the table's order, so that Databricks can read it
 * with {@code read_files} and the table's schema, which matches fields to
 * columns by position, not by name. CSV columns the table doesn't have are
 * dropped, and table columns the CSV doesn't have are NULL, or derived from
 * another column (see {@link #DERIVED}).
 * <p>
 * An empty string is '', never NULL, as in a ClickHouse String, which the SQL
 * relies on; an empty number, quoted or not, is NULL, or 0 in a NOT NULL
 * column. NULL is written as {@link #NULL_MARKER}, which read_files must be
 * given as its nullValue; strings are always quoted, so an empty one is "".
 * Timestamps are UTC, and written in ISO 8601 with a "Z", so they read the same
 * whatever the session's time zone: IEM's "2025-01-01 00:51" becomes
 * "2025-01-01T00:51:00Z".
 */
final class CsvConverter {

    static final String NULL_MARKER = "\\N";
    private static final byte[] NULL_BYTES = NULL_MARKER.getBytes(StandardCharsets.US_ASCII);

    /** A column filled in from another CSV column. */
    record Derived(String from, UnaryOperator<String> function) {
    }

    /** Columns computed by the loader; see sql/10_ontime.sql. */
    static final Map<String, Derived> DERIVED = Map.of(
            "tail", new Derived("Tail_Number", CsvConverter::normaliseTail));

    /**
     * The aircraft registration, as BTS should have written it: Allegiant omits
     * the US "N" prefix (816NV for N816NV), and a few are in lower case.
     */
    static String normaliseTail(String tailNumber) {
        String t = !tailNumber.isEmpty() && Character.isDigit(tailNumber.charAt(0)) ? "N" + tailNumber : tailNumber;
        return t.toUpperCase(Locale.ROOT);
    }

    /** A table column, as information_schema.columns describes it. */
    record TableColumn(String name, String type, boolean nullable) {
    }

    private enum Kind { STRING, NUMBER, DATE, TIMESTAMP }

    /** One output column: where its value comes from, and how to write it. */
    private record Column(String name, Kind kind, boolean required, int source, UnaryOperator<String> derive) {
    }

    private final Column[] columns;
    private final int fields;

    // The current line's fields, copied out of the reader.
    private byte[] line = new byte[1 << 12];
    private final int[] starts;
    private final int[] lens;
    private final boolean[] quoted;

    /**
     * @param header the CSV header fields
     * @param schema the table's columns, in order
     */
    CsvConverter(List<String> header, List<TableColumn> schema) {
        fields = header.size();
        starts = new int[fields];
        lens = new int[fields];
        quoted = new boolean[fields];
        columns = new Column[schema.size()];
        for (int c = 0; c < schema.size(); c++) {
            TableColumn f = schema.get(c);
            String name = f.name();
            Kind kind = kind(f);
            boolean required = !f.nullable();
            int source = header.indexOf(name);
            UnaryOperator<String> derive = null;
            if (source < 0 && DERIVED.containsKey(name)) {
                source = header.indexOf(DERIVED.get(name).from());
                derive = DERIVED.get(name).function();
            }
            if (source < 0 && required && kind != Kind.STRING && kind != Kind.NUMBER) {
                throw new IllegalArgumentException("column " + name + " is NOT NULL but not in the CSV header");
            }
            columns[c] = new Column(name, kind, required, source, derive);
        }
    }

    private static Kind kind(TableColumn f) {
        String type = f.type().toUpperCase(Locale.ROOT);
        return switch (type) {
            case "STRING" -> Kind.STRING;
            case "TINYINT", "BYTE", "SMALLINT", "SHORT", "INT", "INTEGER", "BIGINT", "LONG", "FLOAT", "DOUBLE", "BOOLEAN" -> Kind.NUMBER;
            case "DATE" -> Kind.DATE;
            case "TIMESTAMP" -> Kind.TIMESTAMP;
            default -> {
                if (type.startsWith("DECIMAL")) {
                    yield Kind.NUMBER;
                }
                throw new IllegalArgumentException("column " + f.name() + ": type " + type + " is not supported");
            }
        };
    }

    /** Reads the header line of {@code in}. */
    static List<String> readHeader(CsvReader in) throws IOException {
        List<String> header = new ArrayList<>();
        boolean more = true;
        while (more) {
            more = in.next();
            header.add(in.text());
        }
        return header;
    }

    /**
     * Writes the rest of {@code in} (after its header) to {@code out}, and
     * returns the number of rows.
     */
    long write(CsvReader in, OutputStream out) throws IOException {
        long rows = 0;
        while (in.hasMore()) {
            int field = 0;
            int used = 0;
            boolean more = true;
            while (more) {
                more = in.next();
                if (field < fields) {
                    if (used + in.len > line.length) {
                        line = Arrays.copyOf(line, Math.max(line.length * 2, used + in.len));
                    }
                    System.arraycopy(in.buf, in.start, line, used, in.len);
                    starts[field] = used;
                    lens[field] = in.len;
                    quoted[field] = in.quoted;
                    used += in.len;
                }
                field++;
            }
            if (field < fields) {
                throw new IOException("line " + (rows + 2) + " has " + field + " fields, the header " + fields);
            }
            for (int c = 0; c < columns.length; c++) {
                if (c > 0) {
                    out.write(',');
                }
                try {
                    writeValue(columns[c], out);
                } catch (RuntimeException e) {
                    throw new IOException("line " + (rows + 2) + ", column " + columns[c].name() + ": " + e.getMessage(), e);
                }
            }
            out.write('\n');
            rows++;
        }
        return rows;
    }

    private void writeValue(Column c, OutputStream out) throws IOException {
        int s = c.source();
        boolean missing = s < 0 || (lens[s] == 0 && (!quoted[s] || c.kind() != Kind.STRING))
                || (!quoted[s] && lens[s] == 2 && line[starts[s]] == '\\' && line[starts[s] + 1] == 'N');
        if (c.derive() != null) {
            byte[] v = c.derive().apply(s < 0 ? "" : new String(line, starts[s], lens[s], StandardCharsets.UTF_8))
                    .getBytes(StandardCharsets.UTF_8);
            quote(v, 0, v.length, out);
        } else if (missing) {
            if (!c.required()) {
                out.write(NULL_BYTES);
            } else if (c.kind() == Kind.STRING) {
                out.write('"');
                out.write('"');
            } else if (c.kind() == Kind.NUMBER) {
                out.write('0');
            } else {
                throw new IllegalArgumentException("empty, but NOT NULL");
            }
        } else if (c.kind() == Kind.STRING) {
            quote(line, starts[s], lens[s], out);
        } else if (c.kind() == Kind.TIMESTAMP) {
            writeTimestamp(line, starts[s], lens[s], out);
        } else {
            out.write(line, starts[s], lens[s]);
        }
    }

    /**
     * Writes "YYYY-MM-DD hh:mm[:ss]", taken to be UTC, as "YYYY-MM-DDThh:mm:ssZ";
     * anything else as it is.
     */
    private static void writeTimestamp(byte[] b, int off, int len, OutputStream out) throws IOException {
        if ((len != 16 && len != 19) || b[off + 10] != ' ' || b[off + 13] != ':') {
            out.write(b, off, len);
            return;
        }
        out.write(b, off, 10);
        out.write('T');
        out.write(b, off + 11, len - 11);
        if (len == 16) {
            out.write(':');
            out.write('0');
            out.write('0');
        }
        out.write('Z');
    }

    private static void quote(byte[] b, int off, int len, OutputStream out) throws IOException {
        out.write('"');
        int from = off;
        for (int i = off; i < off + len; i++) {
            if (b[i] == '"') {
                out.write(b, from, i + 1 - from);
                out.write('"');
                from = i + 1;
            }
        }
        out.write(b, from, off + len - from);
        out.write('"');
    }

    // ---- CSV reading ----

    /**
     * Reads CSV one field at a time. After {@link #next()}, the field is
     * {@code buf[start, start + len)}, unquoted and unescaped. Unquoted fields
     * are trimmed of spaces and tabs.
     */
    static final class CsvReader {
        private final InputStream in;
        private final byte[] input = new byte[1 << 16];
        private int pos;
        private int limit;
        private boolean eof;

        byte[] buf = new byte[256];
        int start;
        int len;
        boolean quoted;

        CsvReader(InputStream in) {
            this.in = in;
        }

        private int peek() throws IOException {
            if (pos == limit) {
                if (eof) {
                    return -1;
                }
                limit = in.read(input, 0, input.length);
                pos = 0;
                if (limit <= 0) {
                    limit = 0;
                    eof = true;
                    return -1;
                }
            }
            return input[pos] & 0xff;
        }

        /** True if there is another line (blank lines at the end don't count). */
        boolean hasMore() throws IOException {
            int c;
            while ((c = peek()) == '\r' || c == '\n') {
                pos++;
            }
            return c >= 0;
        }

        /** Reads the next field; returns true if more fields follow on this line. */
        boolean next() throws IOException {
            len = 0;
            start = 0;
            quoted = false;
            int c = peek();
            while (c == ' ' || c == '\t') {
                pos++;
                c = peek();
            }
            if (c == '"') {
                quoted = true;
                pos++;
                while (true) {
                    c = peek();
                    if (c < 0) {
                        throw new IOException("unterminated quoted field");
                    }
                    pos++;
                    if (c == '"') {
                        if (peek() == '"') {
                            pos++;
                        } else {
                            break;
                        }
                    }
                    append(c);
                }
                c = peek();
                while (c == ' ' || c == '\t') {
                    pos++;
                    c = peek();
                }
            } else {
                while (c >= 0 && c != ',' && c != '\n' && c != '\r') {
                    append(c);
                    pos++;
                    c = peek();
                }
                while (len > 0 && (buf[len - 1] == ' ' || buf[len - 1] == '\t')) {
                    len--;
                }
            }
            if (c == ',') {
                pos++;
                return true;
            }
            if (c == '\r') {
                pos++;
                if (peek() == '\n') {
                    pos++;
                }
            } else if (c == '\n') {
                pos++;
            } else if (c >= 0) {
                throw new IOException("unexpected character after quoted field: " + (char) c);
            }
            return false;
        }

        private void append(int c) {
            if (len == buf.length) {
                buf = Arrays.copyOf(buf, len * 2);
            }
            buf[len++] = (byte) c;
        }

        String text() {
            return new String(buf, start, len, StandardCharsets.UTF_8);
        }
    }
}
