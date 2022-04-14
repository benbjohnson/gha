FROM litestream/litestream:0.4.0-beta.2 AS litestream

FROM golang:1.18 as builder
COPY . /src/gha
WORKDIR /src/gha
RUN --mount=type=cache,target=/root/.cache/go-build \
	--mount=type=cache,target=/go/pkg \
	go build -ldflags '-s -w -extldflags "-static"' -tags osusergo,netgo,sqlite_omit_load_extension -o /usr/local/bin/gha .


FROM alpine

ENV DSN "/data/db"
ENV REPLICA_URL "s3://gha.litestream.io/db"

EXPOSE 8080

RUN apk add sqlite bash ca-certificates curl
RUN mkdir -p /data

ADD etc/litestream.yml /etc/litestream.yml

COPY --from=builder /usr/local/bin/gha /usr/local/bin/gha
COPY --from=litestream /usr/local/bin/litestream /usr/local/bin/litestream

CMD \
  litestream restore -if-db-not-exists -if-replica-exists "${DSN}" && \
  litestream replicate -exec "gha -dsn $DSN"
