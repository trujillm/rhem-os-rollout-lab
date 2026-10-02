SHELL := /bin/bash
.PHONY: prerequisites install-rhem build-images ami provision enroll verify \
	rollout-good rollout-failure collect-results restore clean-docs

prerequisites:    ; ./scripts/00-prereqs.sh
install-rhem:     ; ./hub/install-rhem.sh
build-images:     ; ./scripts/10-build-images.sh
ami:              ; ./scripts/15-build-ami.sh
provision:        ; ./scripts/20-provision-ec2.sh
enroll:           ; ./scripts/30-enroll-approve.sh
verify:           ; ./scripts/35-verify.sh
rollout-good:     ; ./scripts/40-rollout-good.sh
rollout-failure:  ; ./scripts/50-rollout-failure.sh
collect-results:  ; ./scripts/60-collect-evidence.sh
restore:          ; ./scripts/70-restore.sh
