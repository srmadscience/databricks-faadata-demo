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
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Properties;

import com.clickhouse.client.api.Client;

/**
 * Connection settings for the ClickHouse server.
 * <p>
 * Values are resolved in this order: environment variable, then
 * {@code ./clickhouse.properties} (git-ignored), then built-in default.
 * Credentials must never be committed.
 */
public record ClickHouseConfig(String endpoint, String user, String password, String database) {

    private static final String LOCAL_PROPS = "clickhouse.properties";

    public static ClickHouseConfig load() {
        Properties props = new Properties();
        Path local = Path.of(LOCAL_PROPS);
        if (Files.isReadable(local)) {
            try (InputStream in = Files.newInputStream(local)) {
                props.load(in);
            } catch (IOException e) {
                throw new IllegalStateException("Unable to read " + local.toAbsolutePath(), e);
            }
        }
        return new ClickHouseConfig(
                resolve(props, "CLICKHOUSE_URL", "clickhouse.url", "http://localhost:8123"),
                resolve(props, "CLICKHOUSE_USER", "clickhouse.user", "default"),
                resolve(props, "CLICKHOUSE_PASSWORD", "clickhouse.password", ""),
                resolve(props, "CLICKHOUSE_DATABASE", "clickhouse.database", "faa"));
    }

    private static String resolve(Properties props, String envName, String propName, String dflt) {
        String env = System.getenv(envName);
        if (env != null && !env.isBlank()) {
            return env;
        }
        return props.getProperty(propName, dflt);
    }

    public Client newClient() {
        return clientBuilder().build();
    }

    /** The settings every client shares, for callers that need more. */
    public Client.Builder clientBuilder() {
        return new Client.Builder()
                .addEndpoint(endpoint)
                .setUsername(user)
                .setPassword(password)
                .setDefaultDatabase(database)
                // Standard HTTP Content-Encoding rather than ClickHouse's native
                // framing: a server set to ZSTD network compression would
                // otherwise send frames the client's LZ4-only decoder can't read.
                .useHttpCompression(true)
                // Uploads go uncompressed: the client's pure-Java LZ4 encoder
                // manages ~0.3 MB/s, far slower than a LAN to the server.
                .compressClientRequest(false);
    }
}
