// Copyright 2026 Matt Wise
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

package main

import (
	"context"
	"encoding/json"
	"log/slog"
	"net"
	"net/http"
	"os"
)

// StartControlServer starts an HTTP server on a Unix domain socket.
// The server exposes the application status via /status, /health, and
// /metrics endpoints, providing a reliable IPC channel for the Swift UI
// app and Prometheus scraping.
//
// The metrics parameter is optional (nil-safe). When provided, the /status
// response is enriched with host and per-runner metrics, and the /metrics
// endpoint serves Prometheus text exposition format.
//
// The socket file is removed on shutdown. If the file already exists
// (e.g., from a previous crash), it is removed before binding.
func StartControlServer(ctx context.Context, socketPath string, status *AppStatus, metrics *MetricsCollector, logger *slog.Logger) error {
	// Remove stale socket file from a previous run.
	os.Remove(socketPath)

	mux := http.NewServeMux()

	// GET /status — returns full application state as JSON, enriched with
	// metrics data when available.
	mux.HandleFunc(ControlPathStatus, func(w http.ResponseWriter, r *http.Request) {
		snap := status.Snapshot()

		// Merge metrics into the status snapshot if a collector is running.
		// The nil check makes this handler safe to use when no
		// MetricsCollector was created (e.g., during early startup or in
		// test configurations that skip metrics).
		if metrics != nil {
			ms := metrics.Snapshot()
			snap.Host = &ms.Host
			snap.Aggregate = &ms.Aggregate

			// Enrich per-runner status with metrics data.
			for i, runner := range snap.Runners {
				if rm, ok := ms.Runners[runner.Name]; ok {
					snap.Runners[i].CPUPercent = rm.CPUPercent
					snap.Runners[i].MemoryRSS = rm.MemoryRSS
					snap.Runners[i].UptimeSecs = rm.Uptime
					snap.Runners[i].JobDurSecs = rm.JobDuration
				}
			}
		}

		data, err := json.Marshal(snap)
		if err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		w.Header().Set("Content-Type", ContentTypeJSON)
		w.Write(data)
	})

	// GET /health — simple liveness check.
	mux.HandleFunc(ControlPathHealth, func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", ContentTypeJSON)
		w.Write([]byte(HealthResponseBody))
	})

	// GET /metrics — Prometheus text exposition format. Only registered when
	// a MetricsCollector is available. The handler is provided by promhttp
	// and uses the collector's custom registry, so it only exposes
	// arc-specific metrics (no default Go runtime or process collectors).
	if metrics != nil {
		mux.Handle(ControlPathMetrics, metrics.Handler())
	}

	listener, err := net.Listen("unix", socketPath)
	if err != nil {
		return err
	}

	server := &http.Server{Handler: mux}

	// Shut down when context is cancelled.
	go func() {
		<-ctx.Done()
		server.Close()
		os.Remove(socketPath)
	}()

	logger.Info("control socket listening", "path", socketPath)

	// Serve blocks until the server is closed.
	if err := server.Serve(listener); err != http.ErrServerClosed {
		return err
	}
	return nil
}
