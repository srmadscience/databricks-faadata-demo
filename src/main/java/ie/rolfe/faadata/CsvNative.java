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
import java.time.LocalDate;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import java.util.Map;

/**
 * Converts CSV with a header line to ClickHouse's Native format, so the client
 * parses the text and the server receives ready-made columns. Fields are read
 * the way ClickHouse reads CSV with its default settings: an empty field is
 * NULL in a Nullable column, but a quoted empty one ("", as BTS writes missing
 * times) is 0 or ''; unquoted fields are trimmed of spaces and tabs; CSV
 * columns the table doesn't have are skipped.
 */
final class CsvNative {

    private static final int BLOCK_ROWS = 65_536;

    private final Column[] fields;      // one per CSV field; null = skip it
    private final List<Column> columns; // the table columns being written, in CSV order

    /**
     * @param header      the CSV header fields
     * @param tableTypes  the table's insertable columns: name to ClickHouse type
     */
    CsvNative(List<String> header, Map<String, String> tableTypes) {
        fields = new Column[header.size()];
        columns = new ArrayList<>();
        for (int i = 0; i < header.size(); i++) {
            String name = header.get(i);
            String type = tableTypes.get(name);
            if (type != null && columns.stream().noneMatch(c -> c.name.equals(name))) {
                fields[i] = column(name, type);
                columns.add(fields[i]);
            }
        }
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
     * Writes the rest of {@code in} (after its header) to {@code out} as Native
     * blocks, and returns the number of rows.
     */
    long write(CsvReader in, OutputStream out) throws IOException {
        long rows = 0;
        int blockRows = 0;
        while (in.hasMore()) {
            int field = 0;
            boolean more = true;
            while (more) {
                more = in.next();
                if (field < fields.length && fields[field] != null) {
                    try {
                        fields[field].add(in);
                    } catch (RuntimeException e) {
                        throw new IOException("line " + (rows + 2) + ", column " + fields[field].name
                                + ": cannot read '" + in.text() + "' as " + fields[field].type, e);
                    }
                }
                field++;
            }
            if (field < fields.length) {
                throw new IOException("line " + (rows + 2) + " has " + field + " fields, the header " + fields.length);
            }
            rows++;
            if (++blockRows == BLOCK_ROWS) {
                writeBlock(out, blockRows);
                blockRows = 0;
            }
        }
        if (blockRows > 0) {
            writeBlock(out, blockRows);
        }
        return rows;
    }

    private void writeBlock(OutputStream out, int rows) throws IOException {
        Buf head = new Buf();
        head.varint(columns.size());
        head.varint(rows);
        head.writeTo(out);
        for (Column c : columns) {
            head.clear();
            head.string(c.name.getBytes(StandardCharsets.UTF_8));
            head.string(c.nativeType.getBytes(StandardCharsets.UTF_8));
            head.writeTo(out);
            if (c.nulls != null) {
                c.nulls.writeTo(out);
                c.nulls.clear();
            }
            c.data.writeTo(out);
            c.data.clear();
        }
    }

    // ---- Column types ----

    /** One column of the block being built. */
    private static final class Column {
        final String name;
        final String type;          // the table's type
        final String nativeType;    // the type sent: LowCardinality is left to the server
        final Value value;
        final Buf data = new Buf();
        final Buf nulls;            // Nullable columns: 1 per NULL row, else 0

        Column(String name, String type, String nativeType, Value value, boolean nullable) {
            this.name = name;
            this.type = type;
            this.nativeType = nativeType;
            this.value = value;
            this.nulls = nullable ? new Buf() : null;
        }

        void add(CsvReader in) {
            if (nulls == null) {
                value.write(in, data);
            } else if ((in.len == 0 && !in.quoted) || in.isNullMarker()) {
                nulls.write(1);
                value.writeDefault(data);
            } else {
                nulls.write(0);
                value.write(in, data);
            }
        }
    }

    private interface Value {
        void write(CsvReader in, Buf out);

        void writeDefault(Buf out);
    }

    private static Value value(Writer w, Defaulter d) {
        return new Value() {
            @Override
            public void write(CsvReader in, Buf out) {
                w.write(in, out);
            }

            @Override
            public void writeDefault(Buf out) {
                d.writeDefault(out);
            }
        };
    }

    private interface Writer {
        void write(CsvReader in, Buf out);
    }

    private interface Defaulter {
        void writeDefault(Buf out);
    }

    private static Column column(String name, String type) {
        String t = type;
        if (t.startsWith("LowCardinality(")) {
            t = t.substring("LowCardinality(".length(), t.length() - 1);
        }
        boolean nullable = t.startsWith("Nullable(");
        String inner = nullable ? t.substring("Nullable(".length(), t.length() - 1) : t;
        Value v = switch (inner) {
            case "String" -> value((in, out) -> out.string(in.buf, in.start, in.len), out -> out.varint(0));
            case "UInt8" -> value((in, out) -> out.write((int) in.integer(0, 0xff)), out -> out.write(0));
            case "Int8" -> value((in, out) -> out.write((int) in.integer(Byte.MIN_VALUE, Byte.MAX_VALUE)), out -> out.write(0));
            case "UInt16" -> value((in, out) -> out.short16((int) in.integer(0, 0xffff)), out -> out.short16(0));
            case "Int16" -> value((in, out) -> out.short16((int) in.integer(Short.MIN_VALUE, Short.MAX_VALUE)), out -> out.short16(0));
            case "UInt32" -> value((in, out) -> out.int32((int) in.integer(0, 0xffffffffL)), out -> out.int32(0));
            case "Int32" -> value((in, out) -> out.int32((int) in.integer(Integer.MIN_VALUE, Integer.MAX_VALUE)), out -> out.int32(0));
            case "Int64" -> value((in, out) -> out.int64(in.integer(Long.MIN_VALUE, Long.MAX_VALUE)), out -> out.int64(0));
            case "Float32" -> value((in, out) -> out.int32(Float.floatToRawIntBits(in.float32())), out -> out.int32(0));
            case "Float64" -> value((in, out) -> out.int64(Double.doubleToRawLongBits(in.float64())), out -> out.int64(0));
            case "Date" -> value((in, out) -> out.short16(in.len == 0 ? 0 : (int) in.date()), out -> out.short16(0));
            default -> throw new IllegalArgumentException("column " + name + ": type " + type + " is not supported by --binary");
        };
        return new Column(name, type, t, v, nullable);
    }

    // ---- CSV reading ----

    /**
     * Reads CSV one field at a time. After {@link #next()}, the field is
     * {@code buf[start, start + len)}, unquoted and unescaped.
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

        boolean isNullMarker() {
            return !quoted && len == 2 && buf[0] == '\\' && buf[1] == 'N';
        }

        /** The field as an integer in [min, max]: empty is 0, anything not digits is an error. */
        long integer(long min, long max) {
            if (len == 0) {
                return 0;
            }
            if (len > 18) {
                throw new NumberFormatException("too many digits");
            }
            int i = buf[0] == '-' || buf[0] == '+' ? 1 : 0;
            if (i == len) {
                throw new NumberFormatException("no digits");
            }
            long v = 0;
            for (; i < len; i++) {
                int d = buf[i] - '0';
                if (d < 0 || d > 9) {
                    throw new NumberFormatException("not an integer");
                }
                v = v * 10 + d;
            }
            v = buf[0] == '-' ? -v : v;
            if (v < min || v > max) {
                throw new NumberFormatException("out of range");
            }
            return v;
        }

        private static final float[] FLOAT_POW10 = {1e0f, 1e1f, 1e2f, 1e3f, 1e4f, 1e5f, 1e6f, 1e7f, 1e8f, 1e9f, 1e10f};
        private static final double[] DOUBLE_POW10 = {1e0, 1e1, 1e2, 1e3, 1e4, 1e5, 1e6, 1e7, 1e8, 1e9, 1e10,
            1e11, 1e12, 1e13, 1e14, 1e15, 1e16, 1e17, 1e18, 1e19, 1e20, 1e21, 1e22};

        /**
         * Parses [-+]digits[.digits] as an integer mantissa and a count of
         * decimal places, into decimal[0] and decimal[1]; false if the field is
         * in any other form or has more than 18 digits.
         */
        private boolean decimal(long[] decimal) {
            int i = len > 0 && (buf[0] == '-' || buf[0] == '+') ? 1 : 0;
            long m = 0;
            int digits = 0;
            int places = -1;
            for (; i < len; i++) {
                int c = buf[i];
                if (c == '.' && places < 0) {
                    places = 0;
                } else if (c >= '0' && c <= '9') {
                    if (++digits > 18) {
                        return false;
                    }
                    m = m * 10 + (c - '0');
                    if (places >= 0) {
                        places++;
                    }
                } else {
                    return false;
                }
            }
            if (digits == 0) {
                return false;
            }
            decimal[0] = buf[0] == '-' ? -m : m;
            decimal[1] = Math.max(places, 0);
            return true;
        }

        private final long[] decimal = new long[2];

        /**
         * The field as a Float32, correctly rounded like Float.parseFloat: when
         * the mantissa and 10^places are both exact floats, one IEEE division
         * rounds correctly (Clinger's fast path), which covers values like
         * "-5.00" without making a String.
         */
        float float32() {
            if (len == 0) {
                return 0f;
            }
            if (decimal(decimal) && Math.abs(decimal[0]) < (1L << 24) && decimal[1] < FLOAT_POW10.length) {
                float v = (float) Math.abs(decimal[0]) / FLOAT_POW10[(int) decimal[1]];
                return buf[0] == '-' ? -v : v;
            }
            return Float.parseFloat(text());
        }

        /** The field as a Float64, correctly rounded like Double.parseDouble (see float32). */
        double float64() {
            if (len == 0) {
                return 0d;
            }
            if (decimal(decimal) && Math.abs(decimal[0]) < (1L << 53) && decimal[1] < DOUBLE_POW10.length) {
                double v = (double) Math.abs(decimal[0]) / DOUBLE_POW10[(int) decimal[1]];
                return buf[0] == '-' ? -v : v;
            }
            return Double.parseDouble(text());
        }

        /** The field as YYYY-MM-DD, in days since 1970-01-01. */
        long date() {
            if (len != 10 || buf[4] != '-' || buf[7] != '-') {
                throw new IllegalArgumentException("not a YYYY-MM-DD date");
            }
            return LocalDate.of(digits(0, 4), digits(5, 2), digits(8, 2)).toEpochDay();
        }

        private int digits(int from, int n) {
            int v = 0;
            for (int i = from; i < from + n; i++) {
                int d = buf[i] - '0';
                if (d < 0 || d > 9) {
                    throw new NumberFormatException("not a date");
                }
                v = v * 10 + d;
            }
            return v;
        }
    }

    // ---- Native writing ----

    /** A growable little-endian byte buffer. */
    private static final class Buf {
        private byte[] b = new byte[1 << 12];
        private int n;

        private void room(int bytes) {
            if (n + bytes > b.length) {
                b = Arrays.copyOf(b, Math.max(b.length * 2, n + bytes));
            }
        }

        void write(int v) {
            room(1);
            b[n++] = (byte) v;
        }

        void short16(int v) {
            room(2);
            b[n++] = (byte) v;
            b[n++] = (byte) (v >> 8);
        }

        void int32(int v) {
            room(4);
            for (int i = 0; i < 4; i++) {
                b[n++] = (byte) (v >> (8 * i));
            }
        }

        void int64(long v) {
            room(8);
            for (int i = 0; i < 8; i++) {
                b[n++] = (byte) (v >> (8 * i));
            }
        }

        void varint(long v) {
            room(10);
            while ((v & ~0x7fL) != 0) {
                b[n++] = (byte) ((v & 0x7f) | 0x80);
                v >>>= 7;
            }
            b[n++] = (byte) v;
        }

        void string(byte[] s) {
            string(s, 0, s.length);
        }

        void string(byte[] s, int off, int len) {
            varint(len);
            room(len);
            System.arraycopy(s, off, b, n, len);
            n += len;
        }

        void writeTo(OutputStream out) throws IOException {
            out.write(b, 0, n);
        }

        void clear() {
            n = 0;
        }
    }
}
