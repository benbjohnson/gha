gha
===

SQLite load testing application using GitHub Archive data. This is used as a
long-running testbed for [litestream](https://github.com/benbjohnson/litestream).


## Usage

```
# Start application with an ingest rate of 100 operations per second.
$ gha -ingest-rate 100
```


## Fly.io

### Deploy

To deploy to fly.io, run:

```sh
$ fly deploy
```


### Volume

```sh
$ fly volume create data --region iad
```

