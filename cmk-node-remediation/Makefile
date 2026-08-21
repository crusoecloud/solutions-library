.PHONY: build fmt test lint vendor docker-build docker-push docker-build-push clean

# Load dev-specific config (IMAGE_REPO, IMAGE_TAG) from .env if present
-include .env

BINARY_NAME=crusoe-node-remediation
IMAGE_TAG?=v0.0.34
IMAGE_REPO?=

build:
	CGO_ENABLED=0 go build -o bin/$(BINARY_NAME) ./cmd/manager

fmt:
	go fmt ./...

test:
	go test -v -race ./...

lint:
	go vet ./...

# Cross-compile for linux/amd64 (host may be arm64/Colima)
docker-build:
	CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o bin/$(BINARY_NAME) ./cmd/manager
	cp bin/$(BINARY_NAME) ./$(BINARY_NAME)
	docker buildx build --platform linux/amd64 --provenance=false \
		-t $(IMAGE_REPO):$(IMAGE_TAG) --load .
	rm -f ./$(BINARY_NAME)

docker-push:
	docker push $(IMAGE_REPO):$(IMAGE_TAG)

# Build and push in one step (avoids OCI manifest list issue)
docker-build-push:
	CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o bin/$(BINARY_NAME) ./cmd/manager
	cp bin/$(BINARY_NAME) ./$(BINARY_NAME)
	docker buildx build --platform linux/amd64 --provenance=false \
		-t $(IMAGE_REPO):$(IMAGE_TAG) --push .
	rm -f ./$(BINARY_NAME)

clean:
	rm -rf bin/
