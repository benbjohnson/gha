FROM golang:1.16 as builder
COPY . /src/gha
WORKDIR /src/gha
RUN --mount=type=cache,target=/root/.cache/go-build \
	--mount=type=cache,target=/go/pkg \
	go build -ldflags '-w -extldflags "-static"' -o /gha .


FROM alpine

# Install s6-overlay for process supervision.
ADD https://github.com/just-containers/s6-overlay/releases/download/v2.2.0.3/s6-overlay-amd64-installer /tmp/
RUN apk upgrade --update && \
	apk add bash && \
	chmod +x /tmp/s6-overlay-amd64-installer && \
	/tmp/s6-overlay-amd64-installer /

# Install litestream.
ADD https://github.com/benbjohnson/litestream/releases/download/v0.3.4-alpha3/litestream-v0.3.4-alpha3-linux-amd64-static /usr/local/bin/litestream
RUN chmod +x /usr/local/bin/litestream

# Copy executable from builder.
COPY --from=builder /gha /usr/local/bin/gha
RUN mkdir -p /data
EXPOSE 7070

# Copy s6 init & service definitions.
COPY etc/cont-init.d /etc/cont-init.d
COPY etc/services.d /etc/services.d
COPY etc/litestream.yml /etc/litestream.yml


#ENV S6_SERVICES_GRACETIME=0
#ENV S6_KILL_GRACETIME=0

# Run the s6 init process on entry.
ENTRYPOINT [ "/init" ]

