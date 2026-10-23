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
COMPOSE        ?= docker compose -f "$(REPO_ROOT)/compose.yaml"

.PHONY: image-build
image-build: ## Build the HerdQuay image (needs a docker login to dhi.io)
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
