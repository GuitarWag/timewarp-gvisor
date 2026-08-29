FROM golang:1.26-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY main.go index.html ./
RUN CGO_ENABLED=0 go build -o /bank .

FROM gcr.io/distroless/static
COPY --from=build /bank /bank
EXPOSE 8090
ENTRYPOINT ["/bank"]
