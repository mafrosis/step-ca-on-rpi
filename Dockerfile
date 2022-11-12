FROM golang:bullseye AS builder

ARG STEP_VERSION=0.15.14
ARG STEP_CERTS_VERSION=0.15.11

RUN apt-get update && apt-get install -y git libpcsclite-dev
RUN git clone -q --branch=v${STEP_CERTS_VERSION} --depth=1 https://github.com/smallstep/certificates
RUN cd certificates && make bootstrap && make build GOFLAGS=""

RUN curl -o /tmp/step.tgz -L https://github.com/smallstep/cli/releases/download/v${STEP_VERSION}/step_linux_${STEP_VERSION}_armv7.tar.gz && \
	tar xzf /tmp/step.tgz --strip-components=1 -C /tmp

# Alternate installation from source
#RUN git clone -q --branch=v${STEP_VERSION} --depth=1 https://github.com/smallstep/cli
#RUN cd cli && make bootstrap && make build


FROM debian:bullseye-slim

COPY --from=builder /tmp/bin/step /usr/local/bin
COPY --from=builder /go/certificates/bin/step-ca /usr/local/bin
COPY --from=builder /go/certificates/bin/step-yubikey-init /usr/local/bin

RUN apt-get update && \
	apt-get install -y ca-certificates jq libpcsclite1

ARG STEPUID=1000
ARG STEPGID=1000
RUN groupadd -r -g ${STEPGID} step && \
	useradd -r -u ${STEPUID} -s /bin/false -M -g step step

RUN mkdir -p /etc/step-ca/db
RUN chown ${STEPUID}:${STEPGID} /etc/step-ca/db/
VOLUME /etc/step-ca/db

USER step

ENV STEPPATH /etc/step-ca

COPY docker-entrypoint.sh /
ENTRYPOINT ["/docker-entrypoint.sh"]
