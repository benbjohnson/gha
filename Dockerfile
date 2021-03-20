FROM golang:1.16 as builder
COPY . /src/gha
WORKDIR /src/gha
RUN go build -ldflags '-w -extldflags "-static"' -o /gha .

FROM alpine
#RUN apk add bash ca-certificates
RUN mkdir -p /var/lib/gha
EXPOSE 7070
COPY --from=builder /gha /usr/local/bin/gha
ENTRYPOINT ["/usr/local/bin/gha", "/var/lib/gha/db"]
