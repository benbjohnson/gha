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
ADD https://github.com/benbjohnson/litestream/releases/download/v0.3.4-alpha1/litestream-v0.3.4-alpha1-linux-amd64-static /usr/local/bin/litestream
RUN chmod +x /usr/local/bin/litestream

# Copy executable from builder.
COPY --from=builder /gha /usr/local/bin/gha
RUN mkdir -p /var/lib/gha

# Copy s6 service definitions.
COPY etc/services.d /etc/services.d

EXPOSE 7070
ENTRYPOINT [ "/init" ]

