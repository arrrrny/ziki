# Changelog

## 1.0.0 - 2026-08-26

- Initial release of `gh-triage`: batch-fetch open GitHub issues, classify each
  as a bug or a feature, label every issue with the configured triage labels
  (opt-out, on by default), and route bugs to the `bug` workflow
  (`bug.fetch` → `bug.assess` → `bug.fix`/`bug.pr`) or features to
  `speckit.specify`.
- Dependency-light engine (`scripts/bash/gh-triage.sh`) uses only `gh` + `jq`.
- Safe by default: assess/labels only; `auto_fix: true` opt-in to run
  `bug.fix` / `bug.pr`.
