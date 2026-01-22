# MySQL Backup

A MySQL backup tool that uses GitHub Actions as a scheduler and GitHub Environments to manage multiple database instances. Backups are stored using [rclone](https://rclone.org/), supporting 70+ cloud storage providers.

## Features

- **Scheduled backups** via GitHub Actions cron
- **Multi-instance support** using GitHub Environments
- **Flexible storage** via rclone (S3, GCS, Azure, Backblaze, SFTP, etc.)
- **Smart schedule classification** (daily, weekly, monthly, yearly)
- **Automatic retention** per backup class
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
│  - Classify schedule → daily/weekly/monthly/yearly          │
│  - mysqldump → gzip → rclone upload                         │
│  - Apply retention per class                                │
│  - Logging to .backup.log                                   │
└─────────────────────────────────────────────────────────────┘
          │
          ▼
┌─────────────────────────────────────────────────────────────┐
│                    rclone destination                       │
│  remote:bucket/                                             │
│  ├── production/                                            │
│  │   ├── daily/            (retention: 7)                  │
│  │   ├── weekly/           (retention: 4)                  │
│  │   ├── monthly/          (retention: 6)                  │
│  │   ├── yearly/           (retention: 2)                  │
│  │   └── X-10_X_X_X_X/     (no retention - manual cleanup) │
│  └── staging/                                               │
│      └── ...                                                │
└─────────────────────────────────────────────────────────────┘
```

## Schedule Classification

The script automatically classifies cron expressions into backup classes:

| Class | Cron Pattern | Example | Folder |
|-------|--------------|---------|--------|
| **daily** | `M H * * *` | `0 2 * * *` (every day at 02:00) | `daily/` |
| **weekly** | `M H * * D` | `0 3 * * 0` (every Sunday at 03:00) | `weekly/` |
| **monthly** | `M H D * *` | `0 4 1 * *` (1st of month at 04:00) | `monthly/` |
| **yearly** | `M H D M *` | `0 5 1 1 *` (Jan 1st at 05:00) | `yearly/` |
| **none** | Complex patterns | `*/10 * * * *` (every 10 min) | `X-10_X_X_X_X/` |

**Retention rules:**
- **Classified schedules** (daily/weekly/monthly/yearly): retention is applied automatically
- **Unclassified schedules** (complex patterns): backups kept indefinitely, manual cleanup required

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
| `MYSQL_PASSWORD` | Database password |
| `RCLONE_CONFIG` | Full rclone.conf content |

And these **variables**:

| Variable | Description |
|----------|-------------|
| `MYSQL_HOST` | Database host |
| `MYSQL_PORT` | Database port (default: 3306) |
| `MYSQL_USER` | Database user |
| `MYSQL_DATABASE` | Database name |
| `RCLONE_DEST` | Destination path (e.g., `myremote:bucket/backups`) |
| `BACKUP_RETENTION` | Retention per class: `daily,weekly,monthly,yearly` (default: `1,1,1,1`) |
| `MYSQL_DUMP_OPTS` | Additional mysqldump options (optional) |

### 3. Configure schedules

Edit `.github/workflows/backup.yml` to set your backup schedules:

```yaml
on:
  schedule:
    - cron: '0 2 * * *'    # Daily at 02:00 UTC → daily/
    - cron: '0 3 * * 0'    # Weekly on Sunday at 03:00 UTC → weekly/
    - cron: '0 4 1 * *'    # Monthly on 1st at 04:00 UTC → monthly/
    - cron: '0 5 1 1 *'    # Yearly on Jan 1st at 05:00 UTC → yearly/
  workflow_dispatch:        # Manual trigger → oneshot/
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

## Retention

`BACKUP_RETENTION` format: `daily,weekly,monthly,yearly`

Example: `7,4,6,2` means:
- Keep **7** daily backups
- Keep **4** weekly backups
- Keep **6** monthly backups
- Keep **2** yearly backups

Default: `1,1,1,1`

**Note:** Retention only applies to classified schedules. Unclassified schedules (like `*/10 * * * *`) are never automatically cleaned up.

## Backup Log

Each folder contains a `.backup.log` file with entries:

```
>>> 2024-01-22 02:00:01 | START | production_mydb_2024-01-22_02-00-01.sql.gz
<<< 2024-01-22 02:00:15 | END   | production_mydb_2024-01-22_02-00-01.sql.gz | 2.5M | OK
>>> 2024-01-23 02:00:01 | START | production_mydb_2024-01-23_02-00-01.sql.gz
!!! 2024-01-23 02:00:03 | ERROR | production_mydb_2024-01-23_02-00-01.sql.gz | exit code: 1
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
| `BACKUP_RETENTION` | No | `1,1,1,1` | Retention: `daily,weekly,monthly,yearly` |
| `MYSQL_DUMP_OPTS` | No | - | Additional mysqldump options |
| `RCLONE_CONFIG` | No | - | Path to rclone config file |

## Local Testing

```bash
# Start test MySQL and run backup
make test-backup

# Clean test environment
make test-clean
```

## License

MIT
