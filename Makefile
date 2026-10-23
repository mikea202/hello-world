# Mikos build entry point. Everything runs in containers; the host needs only docker + make.
SHELL     := /bin/bash
BUILD_IMG := mikos-build:latest
TEST_IMG  := mikos-test:latest
KVM       := $(if $(wildcard /dev/kvm),--device /dev/kvm,)
RUN       := docker run --rm -v $(CURDIR):/src -w /src -e MIKOS_GPG_KEY $(BUILD_IMG)
RUN_PRIV  := docker run --rm --privileged -v $(CURDIR):/src -w /src $(BUILD_IMG)
RUN_TEST  := docker run --rm --cap-add NET_ADMIN -v $(CURDIR):/src -w /src $(TEST_IMG)
PROFILE   ?=

.PHONY: build-image test-image shell debs lint test-pkg repo test-repo image test-vm size clean

build-image:
	docker build -t $(BUILD_IMG) -f build/Dockerfile build

test-image:
	docker build -t $(TEST_IMG) -f build/Dockerfile.test build

shell: build-image
	docker run --rm -it --privileged -v $(CURDIR):/src -w /src $(BUILD_IMG) bash

debs: build-image
	$(RUN) build/scripts/build-debs.sh

lint: build-image
	$(RUN) build/scripts/lint.sh

# Each suite runs in a fresh container so packages are tested on a clean Debian.
test-pkg: test-image
	@for t in tests/pkg/*.bats; do echo "== $$t"; $(RUN_TEST) bats $$t || exit 1; done

repo: build-image
	$(RUN) build/scripts/build-repo.sh

test-repo: test-image
	$(RUN_TEST) bats tests/repo/repo.bats

image: build-image
	$(RUN_PRIV) build/scripts/build-image.sh $(PROFILE)

test-vm: build-image
	docker run --rm $(KVM) -v $(CURDIR):/src -w /src $(BUILD_IMG) tests/vm/boot.sh

size: build-image
	$(RUN) build/scripts/check-size.sh

clean:
	docker run --rm -v $(CURDIR):/src -w /src debian:trixie rm -rf out packages/mikos-base/keyring
