FROM golang:1.26-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY *.go schema.sql ./
COPY web ./web
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -ldflags='-s -w' -o /blink-server .

FROM alpine:3.22
RUN apk add --no-cache ca-certificates
COPY --from=build /blink-server /blink-server
EXPOSE 9000
USER 65532:65532
ENTRYPOINT ["/blink-server"]
