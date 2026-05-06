IMAGE    ?= etchosts-pin
TAG      ?= latest
REGISTRY ?=
PLATFORM ?= linux/amd64

BIN := etchosts-pin

.PHONY: build test docker-build docker-push clean

build:
	CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -ldflags="-s -w" -o $(BIN) .

test:
	go test ./...

docker-build:
	docker buildx build --platform $(PLATFORM) --load -t $(REGISTRY)$(IMAGE):$(TAG) .

docker-push: docker-build
	docker push $(REGISTRY)$(IMAGE):$(TAG)

clean:
	rm -f $(BIN)
