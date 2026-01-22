# MySQL Backup

A MySQL backup tool that uses GitHub Actions as a scheduler and GitHub Environments to manage multiple database instances. Backups are stored using [rclone](https://rclone.org/), supporting 70+ cloud storage providers.

## Features

- **Scheduled backups** via GitHub Actions cron
- **Multi-instance support** using GitHub Environments
- **Flexible storage** via rclone (S3, GCS, Azure, Backblaze, SFTP, etc.)
- **Automatic retention** management per schedule
- **Backup logging** with START/END/ERROR markers
- **Compressed backups** (gzip)

## How It Works

```
┌─────────────────────────────────────────────────────────────┐
│                    GitHub Actions                           │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐         │
│  │ production  │  │   staging   │  │     dev     │  ...    │
│  │ environment │  │ environment │  │ environment │         │
│  └──────┬──────┘  └──────┬──────┘  └──────┬──────┘         │
└─────────┼────────────────┼────────────────┼────────────────┘
          │                │                │
          ▼                ▼                ▼
┌─────────────────────────────────────────────────────────────┐
│                      backup.sh                              │
│  - mysqldump → gzip → rclone upload                         │
│  - Retention cleanup                                        │
│  - Logging to .backup.log                                   │
└─────────────────────────────────────────────────────────────┘
          │
          ▼
┌─────────────────────────────────────────────────────────────┐
│                    rclone destination                       │
│  remote:bucket/                                             │
│  ├── production/                                            │
│  │   ├── 0_2_X_X_X/        (daily at 02:00)                │
│  │   │   ├── .backup.log                                   │
│  │   │   └── production_mydb_2024-01-22_02-00-00.sql.gz    │
│  │   └── 0_3_X_X_0/        (weekly on Sunday at 03:00)     │
│  ├── staging/                                               │
│  │   └── ...                                                │
│  └── dev/                                                   │
│      └── oneshot/          (manual runs)                   │
└─────────────────────────────────────────────────────────────┘
```

## Setup

### 1. Configure rclone

Create an rclone configuration for your storage backend. See [rclone docs](https://rclone.org/docs/) for provider-specific setup.

Example for S3-compatible storage:
```ini
[myremote]
type = s3
provider = AWS
access_key_id = YOUR_ACCESS_KEY
secret_access_key = YOUR_SECRET_KEY
region = us-east-1
```

### 2. Create GitHub Environments

For each database instance you want to backup, create a GitHub Environment with the following **secrets**:

| Secret | Description |
|--------|-------------|
| `MYSQL_HOST` | Database host |
| `MYSQL_PORT` | Database port (default: 3306) |
| `MYSQL_USER` | Database user |
| `MYSQL_PASSWORD` | Database password |
| `MYSQL_DATABASE` | Database name |
| `RCLONE_CONFIG` | Full rclone.conf content |

And these **variables**:

| Variable | Description |
|----------|-------------|
| `RCLONE_DEST` | Destination path (e.g., `myremote:bucket/backups`) |
| `BACKUP_RETENTION` | Number of backups to keep per schedule |
| `MYSQL_DUMP_OPTS` | Additional mysqldump options (optional) |

### 3. Configure schedules

Edit `.github/workflows/backup.yml` to set your backup schedules:

```yaml
on:
  schedule:
    - cron: '0 2 * * *'    # Daily at 02:00 UTC
    - cron: '0 3 * * 0'    # Weekly on Sunday at 03:00 UTC
    - cron: '0 4 1 * *'    # Monthly on 1st at 04:00 UTC
    - cron: '0 5 1 1 *'    # Yearly on Jan 1st at 05:00 UTC
  workflow_dispatch:        # Manual trigger
```

### 4. Add environments to matrix

Edit the workflow to include your environments:

```yaml
strategy:
  matrix:
    environment:
      - production
      - staging
      - dev
```

## Folder Structure

Backups are organized by:
1. **Environment name** (sanitized)
2. **Schedule** (cron expression sanitized: `*` → `X`, space → `_`, `/` → `-`)

| Schedule | Folder |
|----------|--------|
| `0 2 * * *` | `0_2_X_X_X` |
| `0 3 * * 0` | `0_3_X_X_0` |
| `*/5 * * * *` | `X-5_X_X_X_X` |
| Manual run | `oneshot` |

## Backup Log

Each schedule folder contains a `.backup.log` file with entries:

```
>>> 2024-01-22 02:00:01 | START | production_mydb_2024-01-22_02-00-01.sql.gz
<<< 2024-01-22 02:00:15 | END   | production_mydb_2024-01-22_02-00-01.sql.gz | 2.5M | OK
>>> 2024-01-22 02:00:01 | START | production_mydb_2024-01-23_02-00-01.sql.gz
!!! 2024-01-22 02:00:03 | ERROR | production_mydb_2024-01-23_02-00-01.sql.gz | exit code: 1
```

Markers:
- `>>>` = Backup started
- `<<<` = Backup completed successfully
- `!!!` = Backup failed

## Environment Variables

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `BACKUP_NAME` | Yes | - | Environment/instance name |
| `MYSQL_HOST` | Yes | - | Database host |
| `MYSQL_PORT` | No | `3306` | Database port |
| `MYSQL_USER` | Yes | - | Database user |
| `MYSQL_PASSWORD` | Yes | - | Database password |
| `MYSQL_DATABASE` | Yes | - | Database name |
| `RCLONE_DEST` | Yes | - | rclone destination (e.g., `remote:bucket/path`) |
| `BACKUP_SCHEDULE` | No | `oneshot` | Cron expression or "oneshot" for manual |
| `BACKUP_RETENTION` | Yes | - | Number of backups to keep |
| `MYSQL_DUMP_OPTS` | No | - | Additional mysqldump options |
| `RCLONE_CONFIG` | No | - | Path to rclone config file |

## Local Testing

```bash
# Start test MySQL
make test-backup

# Clean test environment
make test-clean
```

## License

MIT
