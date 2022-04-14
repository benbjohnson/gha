gha
===

SQLite load testing application using GitHub Archive data. This is used as a
long-running testbed for [litestream](https://github.com/benbjohnson/litestream).


## Usage

```
gha -ingest-rate 100
```


## Deploy

To deploy to fly.io, run:

```sh
fly launch --name gha --region ord --no-deploy

fly volumes create --region ord --size 1 data

fly secrets set LITESTREAM_ACCESS_KEY_ID=XXX LITESTREAM_SECRET_ACCESS_KEY=YYY

fly deploy
```
