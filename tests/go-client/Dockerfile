FROM golang:1.23-alpine AS build
WORKDIR /src
COPY go.mod .
COPY *.go .
RUN CGO_ENABLED=0 go build -o /inspector .

FROM alpine:3.20
RUN apk add --no-cache ca-certificates
COPY --from=build /inspector /usr/local/bin/inspector
USER 1000
ENTRYPOINT ["inspector"]
