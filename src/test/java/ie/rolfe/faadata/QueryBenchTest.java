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
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.time.LocalDate;
import java.time.temporal.ChronoUnit;
import java.util.List;
import java.util.Random;

import org.junit.jupiter.api.Test;

class QueryBenchTest {

    @Test
    void flightHistoryRangesStayInsideTheDataAndCoverEveryScale() {
        LocalDate first = LocalDate.of(2016, 1, 1);
        LocalDate last = LocalDate.of(2026, 7, 31);
        var workload = new QueryBench.FlightHistory(List.of("N1", "N2"), first, last);
        Random random = new Random(1);
        int[] scales = new int[4];
        for (int i = 0; i < 100_000; i++) {
            QueryBench.Query q = workload.next(random);
            LocalDate from = ((java.sql.Date) q.params().get(1)).toLocalDate();
            LocalDate to = ((java.sql.Date) q.params().get(2)).toLocalDate();
            assertTrue(!from.isBefore(first) && !to.isAfter(last), q.description());
            assertEquals(q.days(), ChronoUnit.DAYS.between(from, to) + 1, q.description());
            assertTrue(q.days() >= 1 && q.days() <= QueryBench.FlightHistory.MAX_DAYS, q.description());
            scales[q.days() <= 7 ? 0 : q.days() <= 31 ? 1 : q.days() <= 365 ? 2 : 3]++;
        }
        for (int n : scales) {
            assertTrue(n > 10_000, "a range scale is rare: " + java.util.Arrays.toString(scales));
        }
    }
}
