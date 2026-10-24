# Image d'outillage des jobs lint, molecule et check:prod-releases du .gitlab-ci.yml :
#   docker build -f ci/ansible-ci.Dockerfile -t registry.exemple.local/outillage/ansible-ci:2026.10 .
#   docker push registry.exemple.local/outillage/ansible-ci:2026.10
# Le job molecule a besoin d'un démon Docker (service docker:dind ou socket du runner).
FROM docker.io/library/python:3.12-slim-bookworm

ARG YQ_VERSION=v4.44.3
RUN apt-get update \
 && apt-get install -y --no-install-recommends git curl ca-certificates openssh-client docker.io \
 && rm -rf /var/lib/apt/lists/* \
 && curl -fsSL -o /usr/local/bin/yq "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_amd64" \
 && chmod +x /usr/local/bin/yq

COPY requirements-dev.txt /tmp/requirements-dev.txt
RUN pip install --no-cache-dir -r /tmp/requirements-dev.txt && rm /tmp/requirements-dev.txt
