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
import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.SQLException;
import java.util.Properties;

/**
 * Connection settings for the Databricks workspace and SQL warehouse.
 * <p>
 * Values are resolved in this order: environment variable, then
 * {@code ./databricks.properties} (git-ignored), then built-in default.
 * Credentials must never be committed.
 * <p>
 * The SQL always names its tables {@code faa.<table>}: {@code faa} is the
 * schema, and the catalog is the connection's default ({@link #catalog()}).
 * Files are uploaded to the volume {@code <catalog>.faa.staging}.
 */
public record DatabricksConfig(String host, String token, String warehouseId, String catalog) {

    private static final String LOCAL_PROPS = "databricks.properties";
    public static final String SCHEMA = "faa";
    public static final String VOLUME = "staging";

    public static DatabricksConfig load() {
        Properties props = new Properties();
        Path local = Path.of(LOCAL_PROPS);
        if (Files.isReadable(local)) {
            try (InputStream in = Files.newInputStream(local)) {
                props.load(in);
            } catch (IOException e) {
                throw new IllegalStateException("Unable to read " + local.toAbsolutePath(), e);
            }
        }
        DatabricksConfig config = new DatabricksConfig(
                // "https://dbc-123.cloud.databricks.com/" -> "dbc-123.cloud.databricks.com"
                resolve(props, "DATABRICKS_HOST", "databricks.host", "").replaceFirst("^https?://", "").replaceFirst("/+$", ""),
                resolve(props, "DATABRICKS_TOKEN", "databricks.token", ""),
                // the ID, or the HTTP path /sql/1.0/warehouses/<id>
                resolve(props, "DATABRICKS_WAREHOUSE_ID", "databricks.warehouse_id", "").replaceFirst(".*/", ""),
                resolve(props, "DATABRICKS_CATALOG", "databricks.catalog", "main"));
        if (config.host.isEmpty() || config.token.isEmpty() || config.warehouseId.isEmpty()) {
            throw new IllegalStateException("set databricks.host, databricks.token and databricks.warehouse_id in "
                    + LOCAL_PROPS + " (see databricks.properties.example), or DATABRICKS_HOST / _TOKEN / _WAREHOUSE_ID");
        }
        return config;
    }

    private static String resolve(Properties props, String envName, String propName, String dflt) {
        String env = System.getenv(envName);
        if (env != null && !env.isBlank()) {
            return env.strip();
        }
        return props.getProperty(propName, dflt).strip();
    }

    /** The SQL warehouse's HTTP path, as shown under its Connection details. */
    public String httpPath() {
        return "/sql/1.0/warehouses/" + warehouseId;
    }

    /** The staging volume's path, e.g. /Volumes/main/faa/staging. */
    public String volumePath() {
        return "/Volumes/" + catalog + "/" + SCHEMA + "/" + VOLUME;
    }

    /** A new JDBC connection to the SQL warehouse, with {@link #catalog()} as its default catalog. */
    public Connection newConnection() throws SQLException {
        Properties p = new Properties();
        p.setProperty("AuthMech", "3");   // personal access token
        p.setProperty("UID", "token");
        p.setProperty("PWD", token);
        p.setProperty("ConnCatalog", catalog);
        p.setProperty("UserAgentEntry", "databricks-faadata-demo");
        return DriverManager.getConnection("jdbc:databricks://" + host + ":443/default;transportMode=http;ssl=1;httpPath="
                + httpPath(), p);
    }
}
