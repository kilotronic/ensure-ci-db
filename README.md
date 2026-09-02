# ensure-ci-db

Idempotent **Postgres-in-a-container** for CI. Brings up (or reuses) a named
container on a host port, refuses to steal a port owned by someone else's
service, and tears it down with `--cleanup`.

Ships as a **CLI** (`./ensure-ci-db.sh`) and a **GitHub Action**.

Self-hosted runners typically leave the container running between jobs
(`--restart unless-stopped`). GitHub-hosted jobs should pass `cleanup: true`
in a final `always()` step.

## GitHub Action

```yaml
- uses: kilotronic/ensure-ci-db@v1
  with:
    database: myapp
    user: myapp
    password: testpassword

# GitHub-hosted only — skip on a persistent self-hosted fleet:
- if: always()
  uses: kilotronic/ensure-ci-db@v1
  with:
    cleanup: true
    database: myapp
    user: myapp
    password: testpassword
```

Pin a commit SHA in production (Renovate's `pinGitHubActionDigests` does this).

## CLI

```bash
export CI_PG_PORT=5433          # default
export CI_PG_DB=ci              # default
export CI_PG_USER=ci
export CI_PG_PASSWORD=ci
./ensure-ci-db.sh               # ensure
./ensure-ci-db.sh --cleanup      # remove
```

Override the runtime with `CT=podman`.

## License

MIT — Kilotronic LLC
