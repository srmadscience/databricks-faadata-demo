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

import org.junit.jupiter.api.Test;

import ie.rolfe.faadata.CsvConverter.TableColumn;

class CsvConverterTest {

    private static CsvConverter.CsvReader reader(String csv) {
        return new CsvConverter.CsvReader(new ByteArrayInputStream(csv.getBytes(StandardCharsets.UTF_8)));
    }

    /** Every field of one line, as text, with |q if it was quoted. */
    private static List<String> line(CsvConverter.CsvReader in) throws IOException {
        List<String> fields = new ArrayList<>();
        boolean more = true;
        while (more) {
            more = in.next();
            fields.add(in.text() + (in.quoted ? "|q" : ""));
        }
        return fields;
    }

    private static TableColumn notNull(String name, String type) {
        return new TableColumn(name, type, false);
    }

    private static TableColumn nullable(String name, String type) {
        return new TableColumn(name, type, true);
    }

    private static String convert(String csv, List<TableColumn> schema) throws IOException {
        CsvConverter.CsvReader in = reader(csv);
        CsvConverter converter = new CsvConverter(CsvConverter.readHeader(in), schema);
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        converter.write(in, out);
        return out.toString(StandardCharsets.UTF_8);
    }

    @Test
    void readsQuotedEscapedAndTrimmedFields() throws IOException {
        CsvConverter.CsvReader in = reader("a, \"b,c\" ,\"say \"\"hi\"\"\",,\"\", d \r\nx\n\n");
        assertTrue(in.hasMore());
        assertEquals(List.of("a", "b,c|q", "say \"hi\"|q", "", "|q", "d"), line(in));
        assertTrue(in.hasMore());
        assertEquals(List.of("x"), line(in));
        assertFalse(in.hasMore());
    }

    @Test
    void writesTableColumnsInTableOrder() throws IOException {
        // Unknown CSV columns (and BTS's trailing empty one) are dropped, table
        // columns missing from the CSV are NULL, and tail is derived from Tail_Number.
        String csv = "Dep,Extra,Day,Code,Tail_Number,\n"
                + "\"0729\",x,2024-01-02,\"AA\",\"816NV\",\n"
                + ",y,2024-01-03,\"\",\"\",\n"
                + "\"\",z,2024-01-04,\"say \"\"hi\"\"\",\"n346FR\",\n";
        List<TableColumn> schema = List.of(
                notNull("Day", "DATE"),
                nullable("Dep", "INT"),
                notNull("Code", "STRING"),
                nullable("Missing", "DOUBLE"),
                notNull("Count", "INT"),
                notNull("tail", "STRING"));
        assertEquals("""
                2024-01-02,0729,"AA",\\N,0,"N816NV"
                2024-01-03,\\N,"",\\N,0,""
                2024-01-04,\\N,"say ""hi\""",\\N,0,"N346FR"
                """, convert(csv, schema));
    }

    @Test
    void writesTimestampsAsUtcIso() throws IOException {
        List<TableColumn> schema = List.of(
                notNull("station", "STRING"),
                notNull("valid", "TIMESTAMP"),
                nullable("peak", "TIMESTAMP"),
                notNull("wx", "STRING"));
        assertEquals("\"ABE\",2025-01-01T00:51:00Z,\\N,\"-RA\"\n\"ABE\",2025-01-01T01:51:00Z,2025-01-01T01:20:05Z,\"\"\n",
                convert("station,valid,peak,wx\nABE,2025-01-01 00:51,,-RA\nABE,2025-01-01 01:51,2025-01-01 01:20:05,\n",
                        schema));
    }

    @Test
    void rejectsShortLinesAndMissingRequiredDates() throws IOException {
        List<TableColumn> schema = List.of(notNull("a", "STRING"));
        assertThrows(IOException.class, () -> convert("a,b\nx\n", schema));
        assertThrows(IOException.class, () -> convert("d\n\n2024-01-01\n,\n",
                List.of(notNull("d", "DATE"))));
        assertThrows(IllegalArgumentException.class, () -> convert("x\n1\n",
                List.of(notNull("d", "DATE"))));
    }

    @Test
    void normalisesTails() {
        assertEquals("N816NV", CsvConverter.normaliseTail("816NV"));
        assertEquals("N346FR", CsvConverter.normaliseTail("n346FR"));
        assertEquals("#N/A", CsvConverter.normaliseTail("#N/A"));
        assertEquals("", CsvConverter.normaliseTail(""));
    }
}
