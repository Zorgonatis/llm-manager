# Changelog

All notable changes to the LLM Management Solution will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Profile system: reusable `[profile.<name>]` sections in models.conf with `<args>` blocks
- Backend as runtime argument: `llm serve <model> [profile] [backend]` with order-independent resolution
- `device=` field in backend definitions for automatic `--device` injection
- `llm prune` command to scan and remove models with missing backends or files
- Extended `current_model` format: `model_id|backend|profile` (backwards compatible)

### Changed
- Softer startup: service/instance commands warn instead of failing when model takes time to load
- `build_cmdline()` now accepts optional backend and profile overrides
- `validate_backend()` now accepts optional backend override parameter
- Backend names are resolved against known sets from config files
- Models without profiles or runtime backend still work (backwards compatible)

### Fixed
- Venv path lookup failure when backend has no venv configured

---
