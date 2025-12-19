# Tasks: WiFi Print Server

**Input**: Design documents from `/specs/001-wifi-print-server/`
**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/api.yaml

**Tests**: Tests included per constitution requirement (TDD approach).

**Organization**: Tasks are grouped by user story to enable independent implementation and testing of each story.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (e.g., US1, US2, US3)
- Include exact file paths in descriptions

## Path Conventions

Based on plan.md structure:
- Source: `src/printserver/`, `src/web/`, `src/cli/`
- Scripts: `scripts/`
- Config templates: `config/`
- Tests: `tests/unit/`, `tests/integration/`

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Project initialization and basic structure

- [X] T001 Create project directory structure per plan.md layout
- [X] T002 Initialize Python project with pyproject.toml (Flask, pycups dependencies)
- [X] T003 [P] Configure flake8 and black for Python linting in pyproject.toml
- [X] T004 [P] Configure shellcheck for Bash script linting
- [X] T005 [P] Create pytest configuration in pyproject.toml and tests/conftest.py
- [X] T006 [P] Create .gitignore for Python project

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Core infrastructure that MUST be complete before ANY user story can be implemented

**⚠️ CRITICAL**: No user story work can begin until this phase is complete

- [X] T007 Create configuration module in src/printserver/config.py (load INI files, constants)
- [X] T008 [P] Create CUPS client wrapper in src/printserver/cups_client.py (connection, error handling)
- [X] T009 [P] Create Printer model in src/printserver/printer.py (status, attributes from CUPS)
- [X] T010 [P] Create PrintJob model in src/printserver/job.py (job states, attributes from CUPS)
- [X] T011 Create base Flask application in src/web/app.py (app factory, configuration)
- [X] T012 [P] Create base HTML template in src/web/templates/base.html (Bootstrap 5, responsive layout)
- [X] T013 [P] Create CSS stylesheet in src/web/static/style.css (basic styling)
- [X] T014 Write unit test for config module in tests/unit/test_config.py
- [X] T015 [P] Write unit test for CUPS client in tests/unit/test_cups_client.py (mocked CUPS)
- [X] T016 [P] Write unit test for Printer model in tests/unit/test_printer.py
- [X] T017 [P] Write unit test for PrintJob model in tests/unit/test_job.py

**Checkpoint**: Foundation ready - user story implementation can now begin

---

## Phase 3: User Story 4 - Initial Setup (Priority: P1) 🎯 MVP

**Goal**: First-time user can install and configure the print server with minimal technical knowledge

**Independent Test**: Run install.sh on fresh Raspberry Pi, verify CUPS and Avahi running, printer detected

### Tests for User Story 4

- [X] T018 [P] [US4] Write integration test for install script in tests/integration/test_install.sh (bats)
- [X] T019 [P] [US4] Write integration test for CUPS configuration in tests/integration/test_cups_config.sh

### Implementation for User Story 4

- [X] T020 [US4] Create main installation script in scripts/install.sh (apt packages, Python deps)
- [X] T021 [P] [US4] Create CUPS configuration script in scripts/configure-cups.sh (enable network, sharing)
- [X] T022 [P] [US4] Create CUPS config template in config/cups/cupsd.conf.template
- [X] T023 [P] [US4] Create Avahi configuration script in scripts/configure-avahi.sh (AirPrint service)
- [X] T024 [P] [US4] Create AirPrint service template in config/avahi/airprint.service.template
- [X] T025 [P] [US4] Create WiFi configuration helper in scripts/configure-wifi.sh
- [X] T026 [US4] Create systemd service file in config/systemd/printserver-web.service
- [X] T027 [US4] Add auto-detection of USB printer to scripts/configure-cups.sh
- [X] T028 [US4] Create CLI setup commands in src/cli/setup.py (status check, reconfigure)

**Checkpoint**: Fresh Raspberry Pi can be set up with print server in 15 minutes

---

## Phase 4: User Story 1 - Print from Windows PC (Priority: P1)

**Goal**: Windows users can add and print to the network printer

**Independent Test**: Add printer in Windows Settings using `http://[ip]:631/printers/Brother`, print test page

### Tests for User Story 1

- [X] T029 [P] [US1] Write integration test for IPP endpoint availability in tests/integration/test_ipp.py
- [X] T030 [P] [US1] Write integration test for Samba share (if enabled) in tests/integration/test_samba.sh

### Implementation for User Story 1

- [X] T031 [US1] Configure CUPS for IPP network access in scripts/configure-cups.sh (port 631, BrowseLocalProtocols)
- [X] T032 [P] [US1] Add Samba configuration for SMB printing in scripts/configure-cups.sh (optional)
- [X] T033 [US1] Update install.sh to include Windows printing dependencies
- [X] T034 [US1] Add printer discovery broadcast configuration to Avahi service
- [X] T035 [US1] Document Windows setup instructions in specs/001-wifi-print-server/quickstart.md

**Checkpoint**: Windows PC can discover and print to the network printer

---

## Phase 5: User Story 2 - Web Management Interface (Priority: P2)

**Goal**: Users can view printer status and manage print queue via web browser

**Independent Test**: Navigate to `http://[ip]:5000`, view dashboard, see printer status, view/cancel jobs in queue

### Tests for User Story 2

- [X] T036 [P] [US2] Write contract test for GET /api/status in tests/integration/test_web_routes.py
- [X] T037 [P] [US2] Write contract test for GET /api/printers in tests/integration/test_web_routes.py
- [X] T038 [P] [US2] Write contract test for GET /api/jobs in tests/integration/test_web_routes.py
- [X] T039 [P] [US2] Write contract test for DELETE /api/jobs/{id} in tests/integration/test_web_routes.py

### Implementation for User Story 2

- [X] T040 [US2] Implement /api/status endpoint in src/web/routes.py (server status, printer summary)
- [X] T041 [P] [US2] Implement /api/printers endpoint in src/web/routes.py (list printers)
- [X] T042 [P] [US2] Implement /api/printers/{name} endpoint in src/web/routes.py (printer details)
- [X] T043 [US2] Implement /api/jobs endpoint in src/web/routes.py (list jobs with filters)
- [X] T044 [US2] Implement /api/jobs/{id} GET endpoint in src/web/routes.py (job details)
- [X] T045 [US2] Implement /api/jobs/{id} DELETE endpoint in src/web/routes.py (cancel job)
- [X] T046 [US2] Create dashboard template in src/web/templates/dashboard.html (printer status, server info)
- [X] T047 [US2] Create queue template in src/web/templates/queue.html (job list, cancel buttons)
- [X] T048 [P] [US2] Create JavaScript for dynamic updates in src/web/static/app.js (fetch status, cancel job)
- [X] T049 [US2] Add route handlers for / and /queue in src/web/routes.py (render templates)
- [X] T050 [US2] Ensure responsive layout works on mobile (320px width) in src/web/static/style.css

**Checkpoint**: Web interface shows printer status and allows job management

---

## Phase 6: User Story 3 - Mobile Printing (Priority: P2)

**Goal**: iOS and Android users can print using native device features (AirPrint, IPP)

**Independent Test**: From iPhone, select Print in any app, see printer in list, print successfully

### Tests for User Story 3

- [X] T051 [P] [US3] Write integration test for Avahi AirPrint service publication in tests/integration/test_airprint.sh
- [X] T052 [P] [US3] Write integration test for IPP Everywhere support in tests/integration/test_ipp.py

### Implementation for User Story 3

- [X] T053 [US3] Enhance Avahi service definition for full AirPrint compatibility in config/avahi/airprint.service.template
- [X] T054 [US3] Add URF (raster format) support configuration to CUPS in scripts/configure-cups.sh
- [X] T055 [US3] Verify cups-filters package installed for AirPrint in scripts/install.sh
- [X] T056 [US3] Configure mDNS for IPP Everywhere (Android) in scripts/configure-avahi.sh
- [X] T057 [US3] Document mobile printing setup in specs/001-wifi-print-server/quickstart.md

**Checkpoint**: iOS and Android devices can discover and print to the printer

---

## Phase 7: User Story 5 - Print Server Reliability (Priority: P3)

**Goal**: Print server automatically recovers from restarts and connection issues

**Independent Test**: Reboot Raspberry Pi, verify printing works within 2 minutes without manual intervention

### Tests for User Story 5

- [X] T058 [P] [US5] Write integration test for service auto-start in tests/integration/test_reliability.sh
- [X] T059 [P] [US5] Write integration test for USB reconnection handling in tests/integration/test_reliability.sh

### Implementation for User Story 5

- [X] T060 [US5] Configure systemd service for auto-restart on failure in config/systemd/printserver-web.service
- [X] T061 [US5] Add dependency ordering in systemd (after network, cups) in config/systemd/printserver-web.service
- [X] T062 [US5] Implement USB hotplug detection in scripts/configure-cups.sh (udev rules)
- [X] T063 [P] [US5] Create udev rule for printer reconnection in config/udev/99-printer.rules
- [X] T064 [US5] Add WiFi reconnection handling to web service in src/web/app.py (connection check)
- [X] T065 [US5] Configure CUPS to preserve jobs across restarts in scripts/configure-cups.sh
- [X] T066 [US5] Add health check endpoint in src/web/routes.py (/health for monitoring)

**Checkpoint**: System reliably recovers from all common failure scenarios

---

## Phase 8: Polish & Cross-Cutting Concerns

**Purpose**: Improvements that affect multiple user stories

- [X] T067 [P] Update quickstart.md with all setup instructions
- [X] T068 [P] Create README.md with project overview and quick start
- [X] T069 Code cleanup and ensure PEP 8 compliance across all Python files
- [X] T070 [P] Add structured logging throughout src/printserver/ and src/web/
- [X] T071 Security review: ensure CUPS access restricted to local network
- [X] T072 [P] Add error handling and user-friendly messages to web interface
- [ ] T073 Run full test suite and fix any failures
- [ ] T074 Validate quickstart.md by following steps on fresh Pi

---

## Dependencies & Execution Order

### Phase Dependencies

```
Phase 1 (Setup) ─────────────────────────────────────────────────────►
                 │
                 ▼
Phase 2 (Foundational) ──────────────────────────────────────────────►
                 │
                 ├──────────────┬──────────────┬──────────────┐
                 ▼              ▼              ▼              ▼
         Phase 3 (US4)   Phase 4 (US1)  Phase 5 (US2)  Phase 6 (US3)
         Initial Setup   Windows Print  Web Interface  Mobile Print
              │              │              │              │
              └──────────────┴──────────────┴──────────────┘
                                    │
                                    ▼
                            Phase 7 (US5)
                            Reliability
                                    │
                                    ▼
                            Phase 8 (Polish)
```

### User Story Dependencies

| Story | Depends On | Can Parallel With |
|-------|------------|-------------------|
| US4 (Initial Setup) | Foundational | - |
| US1 (Windows Print) | Foundational, US4 partial | US2, US3 |
| US2 (Web Interface) | Foundational | US1, US3 |
| US3 (Mobile Print) | Foundational, US4 partial | US1, US2 |
| US5 (Reliability) | US1, US2, US3 | - |

### Within Each User Story

1. Tests written FIRST (TDD per constitution)
2. Core functionality implementation
3. Integration and configuration
4. Documentation updates

### Parallel Opportunities

**Phase 2 (Foundational)**:
```bash
# These can run in parallel:
T008: CUPS client wrapper
T009: Printer model
T010: PrintJob model
T012: Base HTML template
T013: CSS stylesheet
T015-T017: Unit tests
```

**Phase 5 (Web Interface)**:
```bash
# These can run in parallel:
T036-T039: Contract tests
T041-T042: Printer endpoints
T048: JavaScript
```

---

## Parallel Example: Phase 2 Foundational

```bash
# Launch all model implementations together:
Task: "Create CUPS client wrapper in src/printserver/cups_client.py"
Task: "Create Printer model in src/printserver/printer.py"
Task: "Create PrintJob model in src/printserver/job.py"

# Launch all unit tests together:
Task: "Write unit test for CUPS client in tests/unit/test_cups_client.py"
Task: "Write unit test for Printer model in tests/unit/test_printer.py"
Task: "Write unit test for PrintJob model in tests/unit/test_job.py"
```

---

## Implementation Strategy

### MVP First (User Stories 4 + 1)

1. Complete Phase 1: Setup
2. Complete Phase 2: Foundational
3. Complete Phase 3: Initial Setup (US4)
4. Complete Phase 4: Windows Printing (US1)
5. **STOP and VALIDATE**: Test Windows printing end-to-end
6. Deploy/demo - this is your MVP!

### Incremental Delivery

1. Setup + Foundational → Foundation ready
2. Add US4 (Initial Setup) → Can install on Pi
3. Add US1 (Windows Print) → **MVP: Windows can print!**
4. Add US2 (Web Interface) → Users can monitor
5. Add US3 (Mobile Print) → Full device coverage
6. Add US5 (Reliability) → Production-ready
7. Polish → Documentation complete

### Single Developer Strategy

1. Complete phases sequentially: 1 → 2 → 3 → 4 → 5 → 6 → 7 → 8
2. Within each phase, leverage [P] parallel opportunities
3. Stop at MVP (after US1) for early testing/feedback

---

## Task Summary

| Phase | User Story | Task Count | Parallel Tasks |
|-------|------------|------------|----------------|
| 1 | Setup | 6 | 4 |
| 2 | Foundational | 11 | 8 |
| 3 | US4 - Initial Setup | 11 | 6 |
| 4 | US1 - Windows Print | 7 | 2 |
| 5 | US2 - Web Interface | 15 | 6 |
| 6 | US3 - Mobile Print | 7 | 2 |
| 7 | US5 - Reliability | 9 | 3 |
| 8 | Polish | 8 | 4 |
| **Total** | | **74** | **35** |

---

## Notes

- [P] tasks = different files, no dependencies
- [Story] label maps task to specific user story for traceability
- Each user story should be independently completable and testable
- Verify tests fail before implementing (TDD)
- Commit after each task or logical group
- Stop at any checkpoint to validate story independently
- MVP = Setup + Foundational + US4 + US1 (Windows printing works)
