default:

deploy:
	mkdir -p dist
	docker run --rm -v "${PWD}":/usr/src/gha -w /usr/src/gha -e GOOS=linux -e GOARCH=amd64 golang:1.15 go build -v -o dist/gha .
	scp -C dist/gha gha.middlemost.com:gha
	ssh gha.middlemost.com "sudo service gha stop && sudo mv gha /usr/local/bin/gha && sudo service gha start"
	rm -rf dist

deploy-litestream:
	scp -C ../litestream/dist/litestream.deb gha.middlemost.com:
	ssh gha.middlemost.com "sudo dpkg -i litestream.deb && \
		sudo systemctl enable litestream && \
		sudo systemctl restart litestream"
