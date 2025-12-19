<!--
Sync Impact Report
==================
Version change: N/A → 1.0.0 (Initial creation)
Added sections:
  - Core Principles (5 principles)
  - Quality Gates
  - Development Workflow
  - Governance
Templates requiring updates:
  - .specify/templates/plan-template.md (✅ reviewed - no changes needed)
  - .specify/templates/spec-template.md (✅ reviewed - no changes needed)
  - .specify/templates/tasks-template.md (✅ reviewed - no changes needed)
Follow-up TODOs: None
-->

# Rpi_printserver Constitution

## Core Principles

### I. Code Quality First

All code MUST be clean, readable, and self-documenting. Functions MUST do one thing well and be named to describe that purpose. Complex logic MUST be broken into smaller, testable units. Magic numbers and strings MUST be extracted to named constants. Code duplication MUST be eliminated through proper abstraction only when the pattern appears three or more times.

### II. Test-Driven Development

Tests MUST be written before implementation code. The Red-Green-Refactor cycle is mandatory:
- Write a failing test that defines expected behavior
- Write minimal code to make the test pass
- Refactor while keeping tests green

Unit tests MUST cover all business logic. Integration tests MUST verify hardware interactions and network communication. Test coverage MUST NOT drop below 80% for new code.

### III. Maintainability

Code MUST be structured for future developers to understand and modify. Dependencies MUST be explicit and minimal. Configuration MUST be externalized from code. Error messages MUST be actionable and include context. Logging MUST provide sufficient information for debugging without exposing sensitive data.

### IV. Modular Architecture

Components MUST have clear boundaries and single responsibilities. Hardware abstraction layers MUST separate business logic from device-specific code. The print server core MUST be testable without physical printer hardware. External dependencies MUST be injected, not hardcoded.

### V. Simplicity

Start with the simplest solution that works. YAGNI (You Aren't Gonna Need It) applies to all features. Premature optimization is prohibited. Complexity MUST be justified by measurable requirements. When in doubt, leave it out.

## Quality Gates

All changes MUST pass these gates before merging:
- All unit tests pass
- All integration tests pass (mocked hardware acceptable in CI)
- No new linting errors or warnings
- Code review approval from at least one maintainer
- Documentation updated for user-facing changes

## Development Workflow

1. **Branch**: Create feature branch from main
2. **Specify**: Define requirements and acceptance criteria
3. **Test**: Write failing tests for new functionality
4. **Implement**: Write code to pass tests
5. **Refactor**: Clean up while tests remain green
6. **Review**: Submit for code review
7. **Merge**: Squash merge to main after approval

## Governance

This constitution supersedes conflicting practices. Amendments require:
- Documented rationale for the change
- Review by project maintainers
- Version increment following semantic versioning

All pull requests MUST verify compliance with these principles. Deviations require explicit justification in the PR description.

**Version**: 1.0.0 | **Ratified**: 2025-12-18 | **Last Amended**: 2025-12-18
