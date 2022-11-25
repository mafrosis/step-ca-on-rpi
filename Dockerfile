ARG STEP_VERSION=0.22.0
ARG STEP_CERTS_VERSION=0.22.1


FROM golang:1.18-alpine as builder

ARG STEP_VERSION
ARG STEP_CERTS_VERSION

RUN apk add --no-cache curl git build-base pcsc-lite-dev

# Fetch source for step-ca, build with CGO enabled
# Binaries step-ca & step-yubikey-init are used in second stage
RUN git clone -q --branch=v${STEP_CERTS_VERSION} --depth=1 https://github.com/smallstep/certificates && \
	cd certificates && make bootstrap && make build GOFLAGS=""

# Download and untar step-cli binary
RUN curl -o /tmp/step.tgz -L https://github.com/smallstep/cli/releases/download/v${STEP_VERSION}/step_linux_${STEP_VERSION}_armv7.tar.gz && \
	tar xzf /tmp/step.tgz --strip-components=1 -C /tmp


FROM alpine:3.16

COPY --from=builder /tmp/bin/step /usr/local/bin
COPY --from=builder /go/certificates/bin/step-ca /usr/local/bin
COPY --from=builder /go/certificates/bin/step-yubikey-init /usr/local/bin

RUN apk add --no-cache ca-certificates jq pcsc-lite-libs

ENV UID=1000
ENV GID=1000

RUN addgroup --gid ${GID} step
RUN adduser \
    --disabled-password \
    --gecos "" \
    --home "/srv" \
    --ingroup step \
    --no-create-home \
    --uid ${UID} \
    step

RUN mkdir -p /etc/step-ca/db
RUN chown step:step /etc/step-ca/db/
VOLUME /etc/step-ca/db

USER step

ENV STEPPATH /etc/step-ca

COPY docker-entrypoint.sh /
ENTRYPOINT ["/docker-entrypoint.sh"]
