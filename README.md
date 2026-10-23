# Mikos

Debian 13 based server distro with a governed AI harness. Spec: `docs/superpowers/specs/2026-10-23-mikos-server-design.md`.

## Build

Requires docker and make (Windows 11: use WSL2).

    make debs lint test-pkg      # build + test packages
    make repo test-repo          # signed local APT repo
    make image PROFILE=test      # test VM image
    make test-vm                 # boot it in QEMU and run smoke tests
    make image size              # release image + size budgets
