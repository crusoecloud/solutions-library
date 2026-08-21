# Runtime stage — Alpine for debugging (exec into pods, shell access)
# Binary is pre-compiled on the host to avoid QEMU segfaults
FROM alpine:3.19

RUN apk add --no-cache ca-certificates && \
    addgroup -g 65532 -S app && \
    adduser -u 65532 -S app -G app

COPY crusoe-node-remediation /crusoe-node-remediation
RUN chmod 0755 /crusoe-node-remediation

USER 65532:65532

ENTRYPOINT ["/crusoe-node-remediation"]
