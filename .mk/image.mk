# MIT License
#
# Copyright (c) 2026 Roberto Leinardi
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

# HerdQuay image targets: build the image, provision the local harness's secrets, and run it with
# Compose on the loopback interface.

IMAGE_NAME     ?= herdquay
IMAGE_TAG      ?= local
IMAGE          := $(IMAGE_NAME):$(IMAGE_TAG)
IMAGE_VERSION  ?= $(shell git -C "$(REPO_ROOT)" describe --tags --always --dirty 2>/dev/null || echo dev)
IMAGE_REVISION ?= $(shell git -C "$(REPO_ROOT)" rev-parse HEAD 2>/dev/null || echo unknown)
IMAGE_CREATED  ?= $(shell date -u +%Y-%m-%dT%H:%M:%SZ)
# The GitHub App is optional: its override file is added only when its key exists.
COMPOSE_FILES  := -f "$(REPO_ROOT)/compose.yaml" $(if $(wildcard $(REPO_ROOT)/local/secrets/github_app_key),-f "$(REPO_ROOT)/compose.github.yaml")
COMPOSE        ?= docker compose $(COMPOSE_FILES)

.PHONY: image-build
image-build: ## Build the HerdQuay image
	docker buildx build --load \
	  --build-arg VERSION="$(IMAGE_VERSION)" \
	  --build-arg REVISION="$(IMAGE_REVISION)" \
	  --build-arg CREATED="$(IMAGE_CREATED)" \
	  -t "$(IMAGE)" "$(REPO_ROOT)"

.PHONY: local-secrets
local-secrets: ## Provision local/secrets/ for the Compose harness, readable by you and UID 568 only
	"$(REPO_ROOT)/scripts/local-secrets.sh"

.PHONY: compose-up
compose-up: image-build ## Start the local harness, SSH on loopback port 2222
	"$(REPO_ROOT)/scripts/local-secrets.sh" --check
	$(COMPOSE) up -d --no-build

.PHONY: compose-down
compose-down: ## Stop the local harness, keeping its volumes
	$(COMPOSE) down

.PHONY: compose-logs
compose-logs: ## Follow the local harness's logs
	$(COMPOSE) logs -f

.PHONY: image-smoke
image-smoke: ## Smoke-test the built image (SSH, doctor, GitHub config, secrets, persistence)
	"$(REPO_ROOT)/tests/smoke.sh"

.PHONY: image-supervision
image-supervision: ## Test the built image's supervision (child death, bounded stop, SIGKILL)
	"$(REPO_ROOT)/tests/supervision.sh"

.PHONY: image-test
image-test: image-smoke image-supervision ## Run every automated image test

.PHONY: projects-test
projects-test: ## Run the five projects' workflows in the running harness (manual, needs network)
	"$(REPO_ROOT)/tests/projects.sh"

.PHONY: check-updates
check-updates: ## Report pinned tools with a newer upstream release
	"$(REPO_ROOT)/scripts/check-updates.sh"
