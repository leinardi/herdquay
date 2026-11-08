---
name: Bug report
about: Report a bug or unexpected behavior
title: "[Bug]: "
labels: ["bug"]
assignees: []
---
## Step 1: Are you in the right place?

* [ ] I have checked that there are no duplicate active or recent issues (bugs, questions, or
  feature requests) describing this problem.
* [ ] I am using the latest released image (`ghcr.io/leinardi/herdquay:latest`), or have tested an
  image built from `main`.
* [ ] This is not a security vulnerability (those go through the private process in SECURITY.md).
* [ ] This is about the HerdQuay image, not about Claude Code, Herdr or opencode themselves.

## Step 2: Describe your environment

<!-- The image version:
docker inspect -f '{{ index .Config.Labels "org.opencontainers.image.version" }}' <container> -->

* HerdQuay image version and digest: `?`
* Orchestrator (Docker Compose, Docker Swarm, other) and Docker Engine version: `?`
* Host operating system and version: `?`
* `herdquay doctor` output (run over SSH; remove anything private): `?`

## Step 3: Describe the problem

### Steps to reproduce

1. ---
2. ---
3. ---

### Observed results

<!-- What happened? This could be a description, error message, or log output. -->

*

### Expected results

<!-- What did you expect to happen? -->

*

### Relevant code, configuration, or data

<!-- Paste the smallest Compose or stack file, or environment, that reproduces the issue. Never
paste a secret: keys, tokens and authorized_keys stay out of issues. -->

```yaml
# Example snippet (replace with your own)
```

### Error / log output

<!-- If you are getting an error, paste the output here. -->

```text
<paste logs or error messages here>
```

<!-- Adding screenshots, screen recordings, or additional context is always helpful. -->
