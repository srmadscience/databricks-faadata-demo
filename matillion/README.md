# FAA2 – Aircraft Operations Analytics

Transformation pipelines that analyze FAA on-time flight data and aircraft registry data in Databricks (default namespace: `workspace.faa`). The focus is on a set of high-utilization ("leased") aircraft: how they fly, how often they divert, and how long they sit idle for maintenance.

## Source Tables

| Table | Description | Key |
|---|---|---|
| `ontime` | Flight-level on-time performance data (dates, tail numbers, cancellations, diversions, distance, delays, air time) | `Tail_Number` |
| `aircraft` | Aircraft registry attributes (manufacturer, model, etc.) | `tail` |
| `leased_airplanes` | Derived: top 300 most-active aircraft since 2025 (built by `setup_leased_airplanes`) | `Tail_Number` |

Join key: `ontime.Tail_Number = aircraft.tail = leased_airplanes.Tail_Number`.

## Pipelines

Run in this order, because the later pipelines depend on `leased_airplanes`:

1. **[setup_leased_airplanes.tran.yaml](<setup_leased_airplanes.tran.yaml>)**: Filters flights from 2025 onward that have a tail number, counts flights per aircraft, ranks the aircraft and keeps the top 300.
   - Output: `leased_airplanes` (overwrite)
2. **[maia-demo-registry-analysis.tran.yaml](<maia-demo-registry-analysis.tran.yaml>)**: Joins leased aircraft to registry attributes and to flights from 2025 onward. Flags cancellation reasons (OK / Maintenance / Other), then aggregates by aircraft, year and month: flight count, distance, delays, elapsed time and average flight length.
   - Output: `leased_plans_summary` (overwrite)
3. **[leased-aircraft-maintenance-gaps.tran.yaml](<leased-aircraft-maintenance-gaps.tran.yaml>)**: Uses window functions on daily flight activity to find each gap of consecutive days without a completed flight per leased aircraft. Each row reports the preceding flying run's start date, days flown, total flight hours, maintenance start and days in maintenance.
   - Output: `aircraft_maintenance_gaps` (overwrite)

Independent:

- **[top10-diversion-distance-aircraft.tran.yaml](<top10-diversion-distance-aircraft.tran.yaml>)**: Ranks aircraft by total distance flown on diverted flights, keeps the top 10, and enriches them with manufacturer and model.
  - Output: `top10_aircraft_diversion_distance` (overwrite)

## Lineage

```
ontime ──► setup_leased_airplanes ──► leased_airplanes
leased_airplanes + aircraft + ontime ──► maia-demo-registry-analysis ──► leased_plans_summary
leased_airplanes + ontime ──► leased-aircraft-maintenance-gaps ──► aircraft_maintenance_gaps
ontime + aircraft ──► top10-diversion-distance-aircraft ──► top10_aircraft_diversion_distance
```

## Conventions

- All sources and outputs use `[Environment Default]` catalog and schema.
- Outputs are fully rebuilt on every run (Rewrite Table).
- Quality rules (`.matillion/config/pipeline_quality_rules.yaml`, warn-level only): no more than 10 components per pipeline, one output per transformation, every branch ends in an output, and no unused components.

## Known Issues

- The descriptions in `setup_leased_airplanes` and `maia-demo-registry-analysis` describe a manufacturer/registry analysis that these pipelines don't perform. They should be corrected.
- There is no orchestration pipeline yet to run the pipelines in dependency order.
