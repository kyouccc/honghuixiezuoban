FROM golang:1.21-alpine AS builder
WORKDIR /app
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -ldflags="-s -w" -o signal-gateway ./cmd/signal-gateway/

FROM alpine:3.19
RUN apk add --no-cache ca-certificates
WORKDIR /app
COPY --from=builder /app/signal-gateway .
EXPOSE 8080 8081
ENTRYPOINT ["./signal-gateway"]
