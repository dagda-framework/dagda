#!/usr/bin/env python3
"""Database outages and adversarial HTTP clients against disposable services."""
import concurrent.futures
import json
import socket
import struct
import time
from support import RuntimeFixture, process_sample, wait_until


def database_failures(fixture):
    request = fixture.request
    active = "SELECT count(*) FROM pg_stat_activity WHERE application_name='dagda-m0' AND state='active'"
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as executor:
        # Confirm the SQL is executing before terminating its backend.
        pending = [executor.submit(request, '/_test/slow?ms=5000') for _ in range(2)]
        wait_until(lambda: fixture.sql(active) == '2')
        fixture.sql("SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE application_name='dagda-m0'")
        for future in pending:
            status, body, _ = future.result(timeout=3)
            assert (status, body['error']['code']) == (503, 'database_unavailable'), (status, body)
        wait_until(lambda: request('/items')[0] == 200)
        print('PASS terminated PostgreSQL backends return 503 and connections recover', flush=True)

        for cycle in range(3):
            pending = [executor.submit(request, '/_test/slow?ms=5000') for _ in range(2)]
            wait_until(lambda: fixture.sql(active) == '2')
            started = time.monotonic()
            fixture.stop_database()  # Only the cluster this fixture owns.
            for future in pending:
                status, body, _ = future.result(timeout=3)
                assert (status, body['error']['code']) == (503, 'database_unavailable'), (status, body)
            assert time.monotonic() - started < 2.5
            for _ in range(4):
                assert request('/items')[0] == 503
            started = time.monotonic()
            assert request('/health/live')[0] == 200
            assert time.monotonic() - started < 0.3
            assert fixture.inflight() == 0
            fixture.start_database()
            wait_until(lambda: request('/items?id=1')[:2] == (200, {'id': 1, 'name': 'Dagda'}))
            # Hold both leases concurrently, so recovery tests both workers.
            recovered = [executor.submit(request, '/_test/slow?ms=100') for _ in range(2)]
            assert all(future.result()[0] == 200 for future in recovered)
            assert request('/items?id=2')[:2] == (200, {'id': 2, 'name': 'Odin'})
            print(f'PASS database outage/restart {cycle + 1}/3; liveness and both workers recover', flush=True)


def raw_response(fixture, payload):
    chunks = []
    with fixture.connect() as client:
        try:
            client.sendall(payload)
        except (BrokenPipeError, ConnectionResetError):
            pass  # Early close is an allowed rejection for oversized input.
        while True:
            try:
                chunk = client.recv(4096)
            except ConnectionResetError:
                break
            if not chunk:
                break
            chunks.append(chunk)
            assert sum(map(len, chunks)) < 65536, 'Unbounded error response'
    return b''.join(chunks)


def http_failures(fixture):
    prefix = b'GET /items HTTP/1.1\r\nHost: localhost\r\n'
    malformed = [
        b'Host: another\r\n', b'Content-Length: -1\r\n',
        b'Content-Length: 0, 0\r\n', b'Content-Length: 999999999999999999999999\r\n',
        b'Content-Length: 0\r\nContent-Length: 1\r\n',
        b'Content-Length:\t0\r\nTransfer-Encoding: chunked\r\n',
        b'Transfer-Encoding: chunked\r\n', b' Bad: folded\r\n',
        b'\tBad: folded\r\n', b'Bad\t: name\r\n', b'Bad(Name): value\r\n',
        b'X-Value: before\x00after\r\n',
    ]
    for headers in malformed:
        response = raw_response(fixture, prefix + headers + b'\r\n')
        assert response.startswith(b'HTTP/1.1 400 '), (headers, response[:100])
    print('PASS malformed framing, header names, control bytes, and folded headers rejected', flush=True)

    oversized = [
        prefix + b'X-Large: ' + b'a' * 32768 + b'\r\n\r\n',
        prefix + b''.join(f'X-{i}: '.encode() + b'a' * 256 + b'\r\n' for i in range(128)) + b'\r\n',
        b'GET /' + b'x' * 10000 + b' HTTP/1.1\r\nHost: localhost\r\n\r\n',
    ]
    for payload in oversized:
        started = time.monotonic()
        response = raw_response(fixture, payload)
        assert not response or response.startswith(b'HTTP/1.1 431 '), response[:100]
        assert time.monotonic() - started < 3
    assert fixture.inflight() == 0
    assert fixture.request('/items')[0] == 200
    print('PASS oversized single/aggregate headers and request lines rejected within bounds', flush=True)

    # A trickle must not restart the absolute read deadline.
    def trickle():
        started = time.monotonic()
        with fixture.connect() as client:
            client.sendall(b'GET /items HTTP/1.1\r\nHost:')
            client.settimeout(0.1)
            while time.monotonic() - started < 3.5:
                try:
                    client.sendall(b' a')
                    if client.recv(1024) == b'':
                        return time.monotonic() - started
                except (BrokenPipeError, ConnectionResetError):
                    return time.monotonic() - started
                except socket.timeout:
                    pass
                time.sleep(0.15)
        raise AssertionError('Trickled headers extended the read deadline')

    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as executor:
        clients = [executor.submit(trickle) for _ in range(8)]
        time.sleep(0.2)
        started = time.monotonic()
        assert fixture.request('/health/live')[0] == 200
        assert time.monotonic() - started < 0.3
        elapsed = [future.result() for future in clients]
        assert all(1.5 < value < 3 for value in elapsed), elapsed
    # Include an idle accepted connection, with no request line at all.
    started = time.monotonic()
    with fixture.connect() as idle:
        assert idle.recv(1024) == b''
    assert time.monotonic() - started < 3
    print('PASS idle and trickling clients expire without blocking healthy clients', flush=True)

    time.sleep(0.7)
    baseline = process_sample(fixture.process.pid)
    for batch in range(20):
        clients = [fixture.connect() for _ in range(8)]
        try:
            for client in clients:
                client.sendall(b'GET /_test/slow?ms=80 HTTP/1.1\r\nHost: localhost\r\n\r\n')
            wait_until(lambda: fixture.inflight() > 0)
            for index, client in enumerate(clients):
                if (index + batch) % 2 == 0:
                    client.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack('ii', 1, 0))
                client.close()
        finally:
            for client in clients:
                client.close()
        wait_until(lambda: fixture.inflight() == 0)
        time.sleep(0.65)  # Account for the transport's 500 ms close grace period.
        fixture.assert_alive()
        assert fixture.request('/items')[0] == 200
    time.sleep(0.7)
    final = process_sample(fixture.process.pid)
    assert final['fds'] <= baseline['fds'] + 2, (baseline, final)
    assert final['threads'] == baseline['threads'], (baseline, final)
    print('PASS 160 disconnects/resets; admitted work drains and descriptors/threads remain bounded', flush=True)
    return {'before_disconnects': baseline, 'after_disconnects': final}


def main():
    with RuntimeFixture() as fixture:
        database_failures(fixture)
        resources = http_failures(fixture)
        (fixture.artifacts / 'result.json').write_text(json.dumps({'passed': True, **resources}, indent=2) + '\n')


if __name__ == '__main__':
    main()
