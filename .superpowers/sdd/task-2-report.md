# Task 2 report: mikos-base package

Implemented all files per brief verbatim; no deviations were needed.

## TDD evidence
RED: `make test-pkg` before build -> `not ok 1 setup_file failed ... E: Unsupported file /src/out/debs/mikos-base_*_all.deb given on commandline` (deb did not exist; expected).
GREEN: `make debs test-pkg` -> built out/debs/mikos-base_1.0.0_all.deb (4216 bytes); bats `1..12`, ok 1-12, 0 failures.

## Files
build/scripts/{gen-dev-key,build-debs}.sh, packages/mikos-base/{debian,files}/..., tests/pkg/mikos-base.bats (per brief). keyring/ and out/ are gitignored.

## Concerns
None. Note: debian:trixie local image lacked nothing needed.
