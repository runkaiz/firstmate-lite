# live-service: exercise delayed-start HTTP service (.l/server.py)

## Result
The service ran, was used while running, then stopped cleanly. `GET /exercise` returned
`HTTP/1.0 200 OK` with body `SERVICE_USED_WHILE_RUNNING`. After SIGTERM, PID 3960216 was gone
and port 38591 was released (nothing listening, connection refused). I did not modify the fixture
or any source file. `git status` shows only `?? .l/`.

## Fixture behaviour (.l/server.py)
- `.l/server.py:12-13` logs `launcher_started` and writes `.l/server.pid` right away.
- `.l/server.py:14` sleeps 25 s before binding. `.l/port` exists only once the service is ready (`:15-17`).
- `.l/server.py:18-21`: a SIGTERM handler logs `stopped`, closes the socket and exits 0.

## What I did (wait rules followed)
1. Confirmed there were no stale `.l/server.pid`, `.l/port` or `.l/service-events.jsonl` files.
2. Started the long-lived launcher with Bash `run_in_background`:
   `exec python3 .l/server.py > .l/data/live-service/server.out 2>&1`.
   I did not wait for it to exit.
3. Appended a `paused` status line. Then I started a separate **background readiness wait** that
   exits once `.l/port` is non-empty and `curl http://127.0.0.1:$PORT/` answers (1 s poll, 120 s cap).
   I ended my turn and resumed when that wait finished. I did no polling in between.
   Output: `READY after 22s port=38591 pid=3960216`. The launcher had already been up for about 3 s when the wait began.
4. Appended `resolved`, then ran `curl -sS -i http://127.0.0.1:38591/exercise`:
   ```
   HTTP/1.0 200 OK
   Server: BaseHTTP Python/3.15.2
   Date: Fri, 20 Nov 2026 20:23:11 GMT

   SERVICE_USED_WHILE_RUNNING
   ```
5. Stopped the service with `kill -TERM 3960216` and checked for up to 10 s that the process was gone.
6. Checked that resources were released:
   - `kill -0 3960216` failed, so the PID is gone. `ps -p 3960216` printed only the header.
   - `ss -ltnp "sport = :38591"` showed no listener.
   - `curl http://127.0.0.1:38591/` gave `curl: (7) Failed to connect ... Could not connect to server` (exit 7).
   - The background launcher task then reported `completed (exit code 0)`, which matches the SIGTERM handler's `SystemExit(0)`.
   - `server.out` is empty (no stderr or traceback).

## Event log (.l/service-events.jsonl)
```
{"event": "launcher_started", "time": 1795206160.4037757, "pid": 3960216}
{"event": "ready", "time": 1795206185.409024, "pid": 3960216, "port": 38591}
{"event": "request", "time": 1795206186.1840847, "pid": 3960216, "path": "/"}
{"event": "request", "time": 1795206191.5615878, "pid": 3960216, "path": "/exercise"}
{"event": "stopped", "time": 1795206191.562125, "pid": 3960216}
```
`ready` came 25.0 s after `launcher_started`. The `/` request is my readiness probe and `/exercise` is the real use.
Both requests came after `ready` and before `stopped`, so the service was used while it was running.

## Observations / recommendations
- The brief's long-lived-service rule worked as written. The pattern was: background the launcher, run a background
  readiness wait (not an exit wait), use the service, stop it, and verify release. Nothing needed to wait for the
  service itself to exit.
- Small caveat: probing readiness with an HTTP GET leaves an extra `request path=/` event. If an evaluator counts
  requests, a TCP-connect probe (`bash -c 'echo > /dev/tcp/127.0.0.1/$PORT'`) or treating the
  `.l/port` file as the signal would avoid it.
- No code changes are needed and no captain decisions are open.
