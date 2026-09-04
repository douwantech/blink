.PHONY: build xbuild deploy run
build:
	go build -o cloudrelay .
xbuild:
	GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build -o cmd/main . && file cmd/main
run: build
	RELAY_TOKEN=$$(python3 -c "import json;print(json.load(open('env/prod.json'))['RELAY_TOKEN'])") PORT=9099 ./cloudrelay
deploy:
	s deploy -t s.prod.yaml -y
