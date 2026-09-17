# Build from the REPO ROOT, not from server/:
#
#   docker buildx build -f server/Dockerfile --platform linux/amd64,linux/arm64 .
#
# Two stages. Stage one compiles; stage two holds only the binary and the
# client, so the shipped image has no shell and no package manager.
#
# TARGETARCH is filled in automatically by buildx for each platform you ask
# for. That is what makes one command produce both amd64 (Erebus) and arm64
# (the VIM3 boards) images from the same file.

# Keep this tag >= the `go` line in server/go.mod. The official golang images
# pin GOTOOLCHAIN=local, so an older builder fails outright rather than
# quietly fetching a newer toolchain.
FROM --platform=$BUILDPLATFORM golang:1.24-alpine AS build
ARG TARGETARCH

WORKDIR /src

# Dependencies first, so editing main.go does not re-download the world.
COPY server/go.mod server/go.sum ./
RUN go mod download

COPY server/main.go ./
# CGO off = a fully static binary that runs in an empty image.
# -s -w strips debug symbols, roughly halving the binary.
RUN CGO_ENABLED=0 GOOS=linux GOARCH=$TARGETARCH \
    go build -trimpath -ldflags="-s -w" -o /out/kagchat .

FROM scratch
COPY --from=build /out/kagchat /kagchat
COPY web /web
WORKDIR /
EXPOSE 8080
USER 65532:65532
ENTRYPOINT ["/kagchat"]
