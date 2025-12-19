# Data Model: WiFi Print Server

**Feature**: 001-wifi-print-server
**Date**: 2025-12-18

## Entities

### Printer

Represents the physical Brother printer connected via USB.

| Field | Type | Description | Source |
|-------|------|-------------|--------|
| name | string | Printer name in CUPS (e.g., "Brother_HL-L2350DW") | CUPS |
| uri | string | Device URI (e.g., "usb://Brother/HL-L2350DW") | CUPS |
| status | enum | Current state: idle, printing, stopped, offline | CUPS |
| status_message | string | Human-readable status (e.g., "Ready", "Out of paper") | CUPS |
| is_accepting_jobs | boolean | Whether printer accepts new jobs | CUPS |
| is_shared | boolean | Whether printer is shared on network | CUPS |
| make_model | string | Printer make and model | CUPS |
| location | string | Optional location description | Config |
| info | string | Optional description | Config |

**State Transitions**:
```
                    ┌──────────┐
                    │ offline  │
                    └────┬─────┘
                         │ USB connected
                         ▼
    ┌─────────┐    ┌──────────┐    ┌──────────┐
    │ stopped │◄───│   idle   │───►│ printing │
    └────┬────┘    └──────────┘    └────┬─────┘
         │              ▲               │
         │              │ job complete  │
         │              └───────────────┘
         │ admin resume
         └──────────────────────────────►
```

### PrintJob

A document submitted for printing.

| Field | Type | Description | Source |
|-------|------|-------------|--------|
| id | integer | Unique job ID | CUPS |
| title | string | Document name | CUPS |
| user | string | Username who submitted | CUPS |
| state | enum | Job state (see below) | CUPS |
| state_message | string | Human-readable state | CUPS |
| size | integer | Job size in bytes | CUPS |
| pages | integer | Number of pages (if known) | CUPS |
| pages_completed | integer | Pages printed so far | CUPS |
| created_at | datetime | When job was submitted | CUPS |
| completed_at | datetime | When job finished (if done) | CUPS |
| printer_name | string | Target printer name | CUPS |

**Job States** (from CUPS IPP):
| State | Value | Description |
|-------|-------|-------------|
| pending | 3 | Waiting in queue |
| pending-held | 4 | Held, waiting for release |
| processing | 5 | Currently printing |
| processing-stopped | 6 | Printing paused |
| canceled | 7 | Canceled by user |
| aborted | 8 | Aborted due to error |
| completed | 9 | Successfully printed |

**State Transitions**:
```
    ┌─────────────┐
    │   pending   │
    └──────┬──────┘
           │
     ┌─────┴─────┐
     ▼           ▼
┌─────────┐ ┌─────────────┐
│canceled │ │ processing  │
└─────────┘ └──────┬──────┘
                   │
         ┌─────────┼─────────┐
         ▼         ▼         ▼
    ┌─────────┐ ┌─────────┐ ┌─────────┐
    │ aborted │ │completed│ │canceled │
    └─────────┘ └─────────┘ └─────────┘
```

### PrintQueue

Ordered collection of pending print jobs. This is a virtual entity managed by CUPS.

| Field | Type | Description |
|-------|------|-------------|
| printer_name | string | Associated printer |
| jobs | list[PrintJob] | Jobs in queue order |
| job_count | integer | Number of pending jobs |

### ServerStatus

Overall print server status for dashboard display.

| Field | Type | Description |
|-------|------|-------------|
| hostname | string | Raspberry Pi hostname |
| ip_address | string | Current IP address |
| uptime | integer | Seconds since boot |
| cups_running | boolean | CUPS service status |
| avahi_running | boolean | Avahi service status |
| wifi_connected | boolean | WiFi connection status |
| wifi_ssid | string | Connected network name |
| wifi_signal | integer | Signal strength (%) |
| printers | list[Printer] | Connected printers |

## Relationships

```
┌──────────────┐       ┌──────────────┐
│ ServerStatus │       │   Printer    │
└──────┬───────┘       └──────┬───────┘
       │ 1                    │ 1
       │                      │
       │ has many             │ has many
       │                      │
       │ *                    │ *
┌──────▼───────┐       ┌──────▼───────┐
│   Printer    │       │   PrintJob   │
└──────────────┘       └──────────────┘
```

## Validation Rules

### Printer
- `name`: Required, alphanumeric with underscores, max 127 chars
- `uri`: Required, valid CUPS device URI format
- `status`: Must be valid CUPS printer state

### PrintJob
- `id`: Required, positive integer, unique per printer
- `title`: Required, max 255 chars
- `state`: Must be valid IPP job state (3-9)
- `size`: Non-negative integer
- `pages`: Non-negative integer or null if unknown

## Data Sources

All data is retrieved from CUPS via the pycups library. No persistent storage is required for core functionality.

| Entity | CUPS API Method |
|--------|-----------------|
| Printer | `conn.getPrinters()` |
| Printer status | `conn.getPrinterAttributes()` |
| PrintJob | `conn.getJobs()` |
| Job details | `conn.getJobAttributes()` |
| Cancel job | `conn.cancelJob()` |

## Notes

- CUPS handles all persistence internally
- Job history is available via CUPS (configurable retention)
- No user authentication data stored (CUPS handles auth)
- Configuration stored in standard CUPS/Avahi config files
