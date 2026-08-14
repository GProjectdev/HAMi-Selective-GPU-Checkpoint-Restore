SHELL := /usr/bin/env bash

.PHONY: env run run-no-crd preflight backup install-hami verify-hami build-images deploy baseline hami-pause selective-cr pod-recreation cross-node collect clean rollback

env:
	./scripts/00-generate-experiment-env.sh

run:
	./scripts/00-run-full-experiment.sh --yes

run-no-crd:
	./scripts/00-run-full-experiment.sh --yes --no-crd

preflight:
	./scripts/00-preflight.sh

backup:
	./scripts/01-backup-current-environment.sh

install-hami:
	./scripts/02-install-hami.sh

verify-hami:
	./scripts/03-verify-hami.sh

build-images:
	./scripts/04-build-test-images.sh

deploy:
	./scripts/05-deploy-test-workloads.sh

baseline:
	./scripts/06-run-baseline-test.sh

hami-pause:
	./scripts/07-run-hami-pause-resume-test.sh

selective-cr:
	./scripts/08-run-gcr-criu-selective-test.sh

pod-recreation:
	./scripts/09-run-pod-recreation-test.sh

cross-node:
	./scripts/10-run-cross-node-restore-test.sh

collect:
	./scripts/11-collect-results.sh

clean:
	./scripts/12-clean-test-resources.sh

rollback:
	./scripts/99-rollback-to-original-environment.sh
