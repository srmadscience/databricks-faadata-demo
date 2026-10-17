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

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.Random;

import org.junit.jupiter.api.Test;

class CsvNativeTest {

    private static CsvNative.CsvReader reader(String csv) {
        return new CsvNative.CsvReader(new ByteArrayInputStream(csv.getBytes(StandardCharsets.UTF_8)));
    }

    /** Every field of one line, as [text, quoted]. */
    private static List<String> line(CsvNative.CsvReader in) throws IOException {
        List<String> fields = new ArrayList<>();
        boolean more = true;
        while (more) {
            more = in.next();
            fields.add(in.text() + (in.quoted ? "|q" : ""));
        }
        return fields;
    }

    @Test
    void readsQuotedEscapedAndTrimmedFields() throws IOException {
        CsvNative.CsvReader in = reader("a, \"b,c\" ,\"say \"\"hi\"\"\",,\"\", d \r\nx\n\n");
        assertTrue(in.hasMore());
        assertEquals(List.of("a", "b,c|q", "say \"hi\"|q", "", "|q", "d"), line(in));
        assertTrue(in.hasMore());
        assertEquals(List.of("x"), line(in));
        assertFalse(in.hasMore());
    }

    @Test
    void parsesFloatsLikeJava() throws IOException {
        Random random = new Random(1);
        List<String> values = new ArrayList<>(List.of("-5.00", "0.00", "-0.00", "1148.00", "+3", "16777217",
                "0.1", "3.4028235e38", "1e-50", "123456789.123456789"));
        for (int i = 0; i < 10_000; i++) {
            values.add(String.format("%.2f", (random.nextInt(2_000_000) - 1_000_000) / 100.0));
        }
        CsvNative.CsvReader in = reader(String.join(",", values) + "\n");
        for (String v : values) {
            in.next();
            assertEquals(Float.parseFloat(v), in.float32(), v);
            assertEquals(Float.floatToRawIntBits(Float.parseFloat(v)), Float.floatToRawIntBits(in.float32()), v);
            assertEquals(Double.doubleToRawLongBits(Double.parseDouble(v)), Double.doubleToRawLongBits(in.float64()), v);
        }
    }

    @Test
    void rejectsBadIntegers() throws IOException {
        CsvNative.CsvReader in = reader("256,-1,12.5\n");
        in.next();
        assertThrows(NumberFormatException.class, () -> in.integer(0, 0xff));
        in.next();
        assertThrows(NumberFormatException.class, () -> in.integer(0, 0xff));
        in.next();
        assertThrows(NumberFormatException.class, () -> in.integer(0, 0xffff));
    }

    @Test
    void writesNativeBlocks() throws IOException {
        // Unknown CSV columns (and BTS's trailing empty one) are skipped; a bare
        // empty field is NULL in a Nullable column, a quoted empty one is 0.
        CsvNative.CsvReader in = reader("Day,Extra,Dep,Code,\n2024-01-02,x,\"0729\",\"AA\",\n2024-01-03,y,,\"\",\n");
        CsvNative converter = new CsvNative(CsvNative.readHeader(in),
                Map.of("Day", "Date", "Dep", "Nullable(UInt16)", "Code", "LowCardinality(String)"));
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        assertEquals(2, converter.write(in, out));
        byte[] expected = bytes(
                3, 2,                                           // columns, rows
                3, "Day", 4, "Date", 0x0c, 0x4d, 0x0d, 0x4d,     // 19724, 19725 days
                3, "Dep", 16, "Nullable(UInt16)", 0, 1,         // null map
                0xd9, 0x02, 0, 0,                               // 729, default
                4, "Code", 6, "String", 2, "AA", 0);
        assertEquals(new String(expected, StandardCharsets.ISO_8859_1), out.toString(StandardCharsets.ISO_8859_1));
    }

    private static byte[] bytes(Object... parts) {
        ByteArrayOutputStream b = new ByteArrayOutputStream();
        for (Object p : parts) {
            if (p instanceof String s) {
                b.writeBytes(s.getBytes(StandardCharsets.UTF_8));
            } else {
                b.write((Integer) p);
            }
        }
        return b.toByteArray();
    }
}
