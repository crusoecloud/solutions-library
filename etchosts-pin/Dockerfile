FROM golang:1.26-alpine AS builder
WORKDIR /app
COPY go.mod .
COPY go.sum .
RUN go mod download
COPY *.go .
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o etchosts-pin .

FROM scratch
COPY --from=builder /app/etchosts-pin /etchosts-pin
ENTRYPOINT ["/etchosts-pin"]
