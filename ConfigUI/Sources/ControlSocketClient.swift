import Foundation
import Network

/// A lightweight HTTP client that communicates over a Unix domain socket.
///
/// Used to poll the Go CLI's control API for structured state information,
/// runner details, and health status. This is preferred over parsing stdout
/// because:
/// 1. JSON responses are unambiguous (no false positives from log messages)
/// 2. The Go CLI may buffer stdout, causing delays in pipe-based detection
/// 3. The API provides additional data (idle/busy counts, per-runner state)
///
/// The client uses raw POSIX sockets (not URLSession) because `URLSession`
/// does not support Unix domain sockets on macOS. The Network framework's
/// `NWConnection` could be used but adds unnecessary complexity for simple
/// synchronous GET requests.
///
/// Usage:
/// ```swift
/// let client = ControlSocketClient(socketPath: "/tmp/arc-runner-myconfig.sock")
/// if let status = client.getStatus() {
///     print(status.state) // "running", "idle", etc.
/// }
/// ```
class ControlSocketClient {
    /// Absolute path to the Unix domain socket file.
    let socketPath: String

    init(socketPath: String) {
        self.socketPath = socketPath
    }

    /// The JSON response from `GET /status`. Fields mirror the Go CLI's
    /// `StatusResponse` struct and must stay in sync.
    struct StatusResponse: Codable {
        /// Current state: "running", "idle", "error", "stopping"
        let state: String
        /// Number of runners waiting for jobs
        let idleRunners: Int
        /// Number of runners currently executing jobs
        let busyRunners: Int
        /// Per-runner detail (name, state, current job if any)
        let runners: [RunnerDetail]
        /// Error message, populated when state == "error"
        let error: String?
        /// Host-level resource usage (CPU, memory, disk)
        let host: HostMetrics?
        /// Aggregate job counters (completed, succeeded, failed)
        let aggregate: AggregateMetrics?

        enum CodingKeys: String, CodingKey {
            case state
            case idleRunners = "idle_runners"
            case busyRunners = "busy_runners"
            case runners
            case error
            case host
            case aggregate
        }
    }

    /// Detail for a single runner VM instance.
    struct RunnerDetail: Codable {
        /// The tart VM name (e.g., "runner-1")
        let name: String
        /// Runner state: "idle", "busy", "provisioning", etc.
        let state: String
        /// The GitHub Actions job name, if currently executing one
        let job: String?
        /// The repository that triggered the job
        let repo: String?
        /// CPU usage percentage of the tart process (0-100+)
        let cpuPercent: Double?
        /// Resident set size of the tart process in bytes
        let memoryRss: UInt64?
        /// Runner uptime in seconds since creation
        let uptimeSeconds: Double?
        /// Current job duration in seconds (zero if idle)
        let jobDurationSeconds: Double?

        enum CodingKeys: String, CodingKey {
            case name, state, job, repo
            case cpuPercent = "cpu_percent"
            case memoryRss = "memory_rss"
            case uptimeSeconds = "uptime_seconds"
            case jobDurationSeconds = "job_duration_seconds"
        }
    }

    /// Host-level resource usage metrics reported by the Go CLI via gopsutil.
    /// These represent the physical machine's overall resource consumption,
    /// not just the runners managed by this app.
    struct HostMetrics: Codable {
        /// Overall host CPU usage as a percentage (0--100).
        let cpuPercent: Double
        /// Number of logical CPU cores on the host.
        let cpuCount: Int
        /// Host memory currently in use, in bytes.
        let memoryUsed: UInt64
        /// Total physical memory on the host, in bytes.
        let memoryTotal: UInt64
        /// Host memory usage as a percentage (0--100).
        let memoryPercent: Double
        /// Disk space currently in use on the runner's partition, in bytes.
        let diskUsed: UInt64
        /// Total disk capacity on the runner's partition, in bytes.
        let diskTotal: UInt64
        /// Disk usage as a percentage (0--100).
        let diskPercent: Double
        /// Number of tart VMs currently running on the host.
        let runningVMs: Int

        enum CodingKeys: String, CodingKey {
            case cpuPercent = "cpu_percent"
            case cpuCount = "cpu_count"
            case memoryUsed = "memory_used"
            case memoryTotal = "memory_total"
            case memoryPercent = "memory_percent"
            case diskUsed = "disk_used"
            case diskTotal = "disk_total"
            case diskPercent = "disk_percent"
            case runningVMs = "running_vms"
        }
    }

    /// Aggregate job counters accumulated over the Go CLI process lifetime.
    /// These monotonically increase until the process restarts.
    struct AggregateMetrics: Codable {
        /// Total number of jobs that have finished (succeeded + failed).
        let jobsCompleted: Int64
        /// Number of jobs that exited with a success status.
        let jobsSucceeded: Int64
        /// Number of jobs that exited with a failure status.
        let jobsFailed: Int64
        /// Cumulative wall-clock time of all completed jobs, in seconds.
        let totalJobDurationSeconds: Double

        enum CodingKeys: String, CodingKey {
            case jobsCompleted = "jobs_completed"
            case jobsSucceeded = "jobs_succeeded"
            case jobsFailed = "jobs_failed"
            case totalJobDurationSeconds = "total_job_duration_seconds"
        }
    }

    /// Polls `GET /status` from the control socket.
    ///
    /// - Returns: The decoded status response, or nil if the socket is not
    ///   available, the request fails, or the response cannot be decoded.
    func getStatus() -> StatusResponse? {
        guard let data = httpGet(path: "/status") else { return nil }
        return try? JSONDecoder().decode(StatusResponse.self, from: data)
    }

    /// Polls `GET /health` from the control socket.
    ///
    /// - Returns: `true` if the health endpoint responds successfully,
    ///   `false` if the socket is unavailable or the request fails.
    func isHealthy() -> Bool {
        return httpGet(path: "/health") != nil
    }

    // MARK: - Raw HTTP over Unix Socket

    /// Performs a synchronous HTTP GET request over a Unix domain socket.
    ///
    /// This uses raw POSIX socket APIs because:
    /// - `URLSession` does not support `AF_UNIX` sockets
    /// - `NWConnection` would add async complexity for a simple synchronous poll
    /// - The request/response is trivial (no TLS, no chunked encoding, no redirects)
    ///
    /// The HTTP/1.0 protocol is used (not 1.1) so the server closes the connection
    /// after the response, making EOF detection simple.
    ///
    /// - Parameter path: The HTTP path to request (e.g., "/status").
    /// - Returns: The response body as `Data`, or nil on any failure.
    private func httpGet(path: String) -> Data? {
        // Open a Unix domain socket (SOCK_STREAM = TCP-like connection-oriented)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        // Build the sockaddr_un structure with the socket file path
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else { return nil }

        // Copy the path bytes into the fixed-size sun_path buffer.
        // This unsafe pointer manipulation is required because sun_path
        // is a C fixed-size array, which Swift imports as a tuple.
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            let bound = UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self)
            for (i, byte) in pathBytes.enumerated() {
                bound[i] = byte
            }
        }

        // Connect to the Unix socket
        let connectResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else { return nil }

        // Send a minimal HTTP/1.0 GET request. HTTP/1.0 is used (not 1.1)
        // so the server closes the connection after the response body,
        // making it simple to read until EOF without parsing Content-Length.
        let request = "GET \(path) HTTP/1.0\r\nHost: localhost\r\nConnection: close\r\n\r\n"
        request.withCString { cstr in
            _ = send(fd, cstr, strlen(cstr), 0)
        }

        // Read the full response until the server closes the connection
        var responseData = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let bytesRead = recv(fd, &buffer, buffer.count, 0)
            if bytesRead <= 0 { break }
            responseData.append(contentsOf: buffer[0..<bytesRead])
        }

        // Extract the HTTP body by finding the header/body separator (\r\n\r\n).
        // We don't parse status codes or headers — if we got a response, we
        // assume it's valid. The JSON decoder will catch malformed bodies.
        guard let responseStr = String(data: responseData, encoding: .utf8),
              let bodyRange = responseStr.range(of: "\r\n\r\n") else {
            return nil
        }

        let body = String(responseStr[bodyRange.upperBound...])
        return body.data(using: .utf8)
    }
}
