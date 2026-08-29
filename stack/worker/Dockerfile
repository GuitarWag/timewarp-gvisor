FROM golang:1.26-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY *.go ./
RUN CGO_ENABLED=0 go build -o /worker .

FROM gcr.io/distroless/static
COPY --from=build /worker /worker
EXPOSE 8088
ENTRYPOINT ["/worker"]
