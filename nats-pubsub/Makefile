# Convenience targets. Run `make help` for the list.
.PHONY: help server server-stop go cpp python clean

help:
	@echo "make server       start NATS in Docker (ports 4222, 8222)"
	@echo "make server-stop  stop it"
	@echo "make go           build Go clients into bin/go/"
	@echo "make cpp          build C++ clients into bin/cpp/"
	@echo "make python       install the Python dependency (nats-py)"

server:
	docker compose up -d

server-stop:
	docker compose down

go:
	cd go && go mod tidy && go build -o ../bin/go/ ./cmd/...

cpp:
	cmake -S cpp -B build/cpp -DCMAKE_BUILD_TYPE=Release
	cmake --build build/cpp -j
	mkdir -p bin/cpp && cp build/cpp/publisher build/cpp/subscriber build/cpp/loadtest bin/cpp/

python:
	python3 -m pip install -r python/requirements.txt

clean:
	rm -rf bin build
