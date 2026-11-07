#!/usr/bin/env python3
"""M0 integration gate against an owned, disposable PostgreSQL cluster."""
import concurrent.futures
import signal
import socket
import time
from support import RuntimeFixture, wait_until


def main():
    with RuntimeFixture() as fixture:
        request = fixture.request
        inflight = fixture.inflight
        process = fixture.process
        port = fixture.port
        assert request('/items?id=1')[:2] == (200, {'id': 1, 'name': 'Dagda'})
        assert request('/items?id=2')[:2] == (200, {'id': 2, 'name': 'Odin'})
        assert request('/items?id=999')[0] == 404
        assert request('/items?id=bad')[0] == 400
        assert request('/items', method='POST')[0] == 405
        print('PASS indexed PostgreSQL lookup, parameter decoding, missing rows, methods', flush=True)

        with concurrent.futures.ThreadPoolExecutor(max_workers=16) as executor:
            slow = [executor.submit(request, '/_test/slow?ms=650') for _ in range(2)]
            wait_until(lambda: inflight() == 2)
            started = time.monotonic()
            assert request('/health/live')[0] == 200
            assert time.monotonic() - started < 0.3, 'DB calls blocked the event loop'
            assert all(f.result()[0] == 200 for f in slow)
            print('PASS event loop remains responsive while both workers wait on PostgreSQL', flush=True)

            jobs = [executor.submit(request, '/_test/slow?ms=500') for _ in range(8)]
            wait_until(lambda: inflight() == 8)
            status, body, headers = request('/items')
            assert status == 503 and body['error']['code'] == 'overloaded'
            assert headers.get('retry-after') == '1'
            results = [f.result()[0] for f in jobs]
            assert all(status in (200, 503) for status in results)
            wait_until(lambda: inflight() == 0)
            print('PASS bounded admission, overload rejection, queued request deadlines', flush=True)

            started = time.monotonic()
            status, body, _ = request('/_test/slow?ms=5000')
            assert status == 503 and body['error']['code'] == 'deadline_exceeded'
            assert time.monotonic() - started < 1.8
            active_sql = "SELECT count(*) FROM pg_stat_activity WHERE application_name='dagda-m0' AND state='active'"
            def no_active_queries():
                return fixture.sql(active_sql) == '0'
            wait_until(no_active_queries, timeout=2)
            assert request('/_test/query-error')[0] == 500
            assert request('/items')[0] == 200
            assert request('/items')[0] == 200
            print('PASS query cancellation, SQL failure, and subsequent connection recovery', flush=True)

            for _ in range(8):
                abandoned = socket.create_connection(('127.0.0.1', port))
                abandoned.sendall(b'GET /_test/slow?ms=50 HTTP/1.1\r\nHost: localhost\r\n\r\n')
                abandoned.close()
            time.sleep(0.5)
            wait_until(lambda: inflight() == 0)
            assert process.poll() is None
            assert request('/items')[0] == 200
            print('PASS disconnected clients do not free worker-owned request storage', flush=True)

            for framing in (b'Content-Length: 0\r\nTransfer-Encoding: chunked\r\n',
                            b'Content-Length: 0\r\nContent-Length: 0\r\n'):
                with socket.create_connection(('127.0.0.1', port), timeout=3) as raw:
                    raw.sendall(b'GET /items HTTP/1.1\r\nHost: localhost\r\n' + framing + b'\r\n')
                    assert b' 400 ' in raw.recv(4096)
            print('PASS ambiguous request framing is rejected', flush=True)

            time.sleep(0.6)  # Allow upstream's close-delay timers to finish.
            for _ in range(12):
                assert request('/items?id=1')[1] == {'id': 1, 'name': 'Dagda'}
                assert request('/items?id=2')[1] == {'id': 2, 'name': 'Odin'}
            print('PASS repeated slot reuse preserves response ownership', flush=True)

            slow = executor.submit(request, '/_test/slow?ms=250')
            wait_until(lambda: inflight() == 1)
            # A client that never finishes headers must not hold shutdown open.
            partial = socket.create_connection(('127.0.0.1', port))
            partial.sendall(b'GET /items HTTP/1.1\r\nHost:')
            started = time.monotonic()
            process.send_signal(signal.SIGTERM)
            assert slow.result()[0] == 200
            process.wait(timeout=5)
            partial.close()
            assert process.returncode == 0
            assert time.monotonic() - started < 4
            print('PASS SIGTERM drains active work and expires partial requests', flush=True)


if __name__ == "__main__":
    main()
