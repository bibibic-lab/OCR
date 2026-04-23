FROM alpine:3.19
RUN apk add --no-cache bash curl jq ca-certificates && \
    adduser -D -u 1000 unsealer
COPY unsealer.sh /usr/local/bin/unsealer.sh
RUN chmod 0755 /usr/local/bin/unsealer.sh
USER 1000
ENTRYPOINT ["/bin/sh", "/usr/local/bin/unsealer.sh"]
