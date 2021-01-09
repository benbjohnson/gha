package main

import (
	"compress/gzip"
	"context"
	"database/sql"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"sync"
	"time"

	_ "github.com/mattn/go-sqlite3"
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
	"github.com/prometheus/client_golang/prometheus/promhttp"
	"github.com/rollbar/rollbar-go"
)

// Metrics
var (
	writeTxTotal = promauto.NewCounter(prometheus.CounterOpts{
		Namespace: "gha",
		Name:      "write_tx_total",
		Help:      "Count of write transactions.",
	})

	readTxTotal = promauto.NewCounter(prometheus.CounterOpts{
		Namespace: "gha",
		Name:      "read_tx_total",
		Help:      "Count of read transactions.",
	})
)

// Internal stats.
var stats struct {
	mu            sync.Mutex
	writeN        uint64
	lastCreatedAt time.Time
}

func main() {
	m := NewMain()
	if err := m.Run(context.Background(), os.Args[1:]); err == flag.ErrHelp {
		os.Exit(1)
	} else if err != nil {
		fmt.Fprintln(os.Stderr, err)
		rollbar.Error(err)
		os.Exit(1)
	}
}

type Main struct{}

func NewMain() *Main {
	return &Main{}
}

func (m *Main) Run(ctx context.Context, args []string) (err error) {
	fs := flag.NewFlagSet("gha", flag.ContinueOnError)
	ingestRate := fs.Int("ingest-rate", 1, "")
	//queryRate := fs.Int("query-rate", 1, "")
	fs.Usage = m.Usage
	if err := fs.Parse(args); err != nil {
		return err
	} else if fs.NArg() == 0 {
		return fmt.Errorf("dsn required")
	} else if fs.NArg() > 1 {
		return fmt.Errorf("too many arguments")
	}
	dsn := fs.Arg(0)

	log.SetFlags(0)

	// Enable rollbar if token provided.
	if v := os.Getenv("ROLLBAR_TOKEN"); v != "" {
		rollbar.SetToken(v)
		rollbar.SetEnvironment("production")
		rollbar.SetCodeVersion("v0.1.0")
		rollbar.SetServerRoot("github.com/benbjohnson/gha")
		log.Printf("rollbar error tracking enabled")
		defer func() {
			if r := recover(); r != nil {
				rollbar.Critical(r)
				rollbar.Wait()
				panic(r)
			}
		}()
	}

	// Connect to database.
	if err := os.MkdirAll(filepath.Dir(dsn), 0700); err != nil {
		return err
	}

	db, err := sql.Open("sqlite3", dsn)
	if err != nil {
		return err
	}
	defer db.Close()

	// Setup database schema, if necessary.
	if err := m.migrate(ctx, db); err != nil {
		return fmt.Errorf("migrate: %w", err)
	}

	// Determine max event time.
	var startTimeStr string
	if err := db.QueryRowContext(ctx, `SELECT IFNULL(MAX(created_at), '') FROM events;`).Scan(&startTimeStr); err != nil {
		return fmt.Errorf("cannot determine max event time: %w", err)
	}

	// Default start time to Jan 2015.
	startTime := time.Date(2015, time.January, 1, 0, 0, 0, 0, time.UTC)
	if startTimeStr != "" {
		if startTime, err = time.ParseInLocation(time.RFC3339, startTimeStr, time.UTC); err != nil {
			return fmt.Errorf("cannot parse start time: %w", err)
		}
	}

	ctx, cancel := context.WithCancel(ctx)
	defer cancel()

	go m.logger(ctx)
	go m.ingestor(ctx, db, startTime.Truncate(1*time.Hour), *ingestRate)
	// go m.querier(ctx, db, *queryRate)

	fmt.Println("Metrics available via http://localhost:7070/metrics")
	http.Handle("/metrics", promhttp.Handler())
	return http.ListenAndServe(":7070", nil)
}

func (m *Main) migrate(ctx context.Context, db *sql.DB) error {
	if _, err := db.Exec(`PRAGMA journal_mode = wal;`); err != nil {
		return fmt.Errorf("set wal mode: %w", err)
	}

	tx, err := db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()

	if _, err := tx.Exec(`
		CREATE TABLE IF NOT EXISTS events (
			id INTEGER PRIMARY KEY,
			"type" TEXT,
			actor_id INTEGER,
			repo_id INTEGER,
			created_at TEXT NOT NULL
		);

		CREATE INDEX IF NOT EXISTS events_actor_id_fkey ON events (actor_id);
		CREATE INDEX IF NOT EXISTS events_repo_id_fkey ON events (repo_id);
		CREATE INDEX IF NOT EXISTS events_created_at_key ON events (created_at);
	`); err != nil {
		return fmt.Errorf("create events table: %w", err)
	}

	if _, err := tx.Exec(`
		CREATE TABLE IF NOT EXISTS users (
			id INTEGER PRIMARY KEY,
			login TEXT NOT NULL,
			url TEXT NOT NULL
		);
	`); err != nil {
		return fmt.Errorf("create users table: %w", err)
	}

	if _, err := tx.Exec(`
		CREATE TABLE IF NOT EXISTS repos (
			id INTEGER PRIMARY KEY,
			name TEXT NOT NULL,
			url TEXT NOT NULL
		);
	`); err != nil {
		return fmt.Errorf("create repos table: %w", err)
	}

	return tx.Commit()
}

// logger is run in a separate goroutine and periodically logs event totals.
func (m *Main) logger(ctx context.Context) {
	ticker := time.NewTicker(1 * time.Second)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			stats.mu.Lock()
			log.Printf("status: t=%s writes=%d", stats.lastCreatedAt.Format(time.RFC3339), stats.writeN)
			stats.mu.Unlock()
		}
	}
}

// ingestor is run in a separate goroutine and ingests data from GitHub Archive.
func (m *Main) ingestor(ctx context.Context, db *sql.DB, startTime time.Time, rate int) {
	ticker := time.NewTicker(time.Second / time.Duration(rate))
	defer ticker.Stop()

	ch := newEventStream(startTime)
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}

		event := <-ch
		if err := m.ingest(ctx, db, event); err != nil {
			log.Printf("ingest error: %s", err)
		}
	}
}

// ingest writes a single event to the database.
func (m *Main) ingest(ctx context.Context, db *sql.DB, event Event) error {
	tx, err := db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()

	var actorID, repoID *int
	if event.Actor != nil {
		actorID = &event.Actor.ID
	}
	if event.Repo != nil {
		repoID = &event.Repo.ID
	}

	if _, err := tx.Exec(`
		INSERT INTO events (id, "type", actor_id, repo_id, created_at)
		VALUES (?, ?, ?, ?, ?)
		ON CONFLICT (id) DO NOTHING;
	`,
		event.ID,
		event.Type,
		actorID,
		repoID,
		event.CreatedAt.Format(time.RFC3339),
	); err != nil {
		return fmt.Errorf("insert event: %w", err)
	}

	if err := tx.Commit(); err != nil {
		return err
	}

	writeTxTotal.Inc()

	stats.mu.Lock()
	stats.writeN++
	stats.lastCreatedAt = event.CreatedAt
	stats.mu.Unlock()

	return nil
}

func (m *Main) Usage() {
	fmt.Println(`
GHA is a long-running testbed for litestream.

Usage:

	gha [arguments] DSN

Arguments:

	-ingest-rate NUM
	    Ingestion rate in operations per second. Defaults to 1.

	-query-rate NUM
	    Query rate in queries per second. Defaults to 1.

`[1:])
}

type Event struct {
	ID        int             `json:"id,string"`
	Type      string          `json:"type"`
	Actor     *User           `json:"actor"`
	Repo      *Repo           `json:"repo"`
	Payload   json.RawMessage `json:"payload"`
	CreatedAt time.Time       `json:"created_at"`
}

type User struct {
	ID    int    `json:"id"`
	Login string `json:"login"`
	URL   string `json:"url"`
}

type Repo struct {
	ID   int    `json:"id"`
	Name string `json:"name"`
	URL  string `json:"url"`
}

func newEventStream(startTime time.Time) <-chan Event {
	ch := make(chan Event, 1024)
	go func() {
		for t := startTime; ; {
			if err := processEventStreamAt(ch, t); err != nil {
				log.Printf("cannot process event stream for %s, waiting 1m to retry: %s", t, err)
				time.Sleep(1 * time.Minute)
				continue
			}
			t = t.Add(time.Hour)
		}
	}()
	return ch
}

// processEventStreamAt processes events for a single hour and sends them to ch.
func processEventStreamAt(ch chan Event, t time.Time) error {
	filename := fmt.Sprintf("%04d-%02d-%02d-%d.json.gz", t.Year(), t.Month(), t.Day(), t.Hour())
	rawurl := "https://data.gharchive.org/" + filename

	// Fetch data over HTTP.
	resp, err := http.Get(rawurl)
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	if resp.StatusCode == http.StatusNotFound {
		return fmt.Errorf("file not found: %s", rawurl)
	} else if resp.StatusCode >= 400 {
		return fmt.Errorf("invalid status code: code=%d url=%s", resp.StatusCode, rawurl)
	}

	// Decompress stream.
	gr, err := gzip.NewReader(resp.Body)
	if err != nil {
		return err
	}
	defer gr.Close()

	// Read data as JSON.
	dec := json.NewDecoder(gr)
	for {
		var event Event
		if err := dec.Decode(&event); err == io.EOF {
			return nil
		} else if err != nil {
			return err
		}
		ch <- event
	}

	return nil
}
