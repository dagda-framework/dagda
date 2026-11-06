#!/usr/bin/env python3
"""M0 integration gate. Creates and removes its OWN PostgreSQL cluster only."""
import concurrent.futures
import http.client
import json
import os
from pathlib import Path
import shutil
import signal
import socket
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]


def wait_until(predicate, timeout=5):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            if predicate():
                return
        except (OSError, http.client.HTTPException):
            pass
        time.sleep(0.025)
    raise AssertionError('Condition did not become true before timeout')


def main():
    for command in ('initdb', 'pg_ctl', 'psql'):
        if not shutil.which(command):
            raise SystemExit(f'Missing test dependency: {command}')
    with tempfile.TemporaryDirectory(prefix='dagda-m0-') as temporary:
        directory = Path(temporary)
        database = directory / 'postgres'
        log = directory / 'postgres.log'
        server_log = directory / 'server.log'
        pg_started = False
        process = None
        output = None
        try:
            subprocess.run(['initdb', '-D', str(database), '-A', 'trust', '--no-locale', '-E', 'UTF8'],
                           check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
            # Unix socket only. No port publishing or connection to an existing DB.
            subprocess.run(['pg_ctl', '-D', str(database), '-l', str(log), '-o',
                            f"-k {directory} -h '' -p 55439 -F", '-w', 'start'],
                           check=True, stdout=subprocess.DEVNULL)
            pg_started = True
            conninfo = f'host={directory} port=55439 dbname=postgres application_name=dagda-m0'
            subprocess.run(['psql', conninfo, '-v', 'ON_ERROR_STOP=1', '-f', str(ROOT / 'tests/seed.sql')],
                           check=True, stdout=subprocess.DEVNULL)
            with socket.socket() as reservation:
                reservation.bind(('127.0.0.1', 0))
                port = reservation.getsockname()[1]
            env = dict(os.environ, DAGDA_DATABASE_URL=conninfo,
                       DAGDA_LISTEN=f'127.0.0.1:{port}', DAGDA_TEST_ROUTES='1', DAGDA_DEADLINE_MS='1200')
            output = server_log.open('w')
            process = subprocess.Popen([str(ROOT / 'build/dagda-m0')], env=env, stdout=output, stderr=output)

            def request(path, method='GET'):
                connection = http.client.HTTPConnection('127.0.0.1', port, timeout=5)
                try:
                    connection.request(method, path)
                    response = connection.getresponse()
                    payload = response.read()
                    headers = dict(response.getheaders())
                    try:
                        body = json.loads(payload)
                    except json.JSONDecodeError as error:
                        raise AssertionError(f'{path}: status={response.status}, headers={headers!r}, body={payload!r}') from error
                    return response.status, body, headers
                finally:
                    connection.close()

            def inflight():
                return request('/_test/state')[1]['inflight']

            wait_until(lambda: request('/health/live')[0] == 200)
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
                    result = subprocess.run(['psql', conninfo.replace('application_name=dagda-m0', 'application_name=test-monitor'), '-Atc', active_sql],
                                            check=True, capture_output=True, text=True)
                    return result.stdout.strip() == '0'
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
        except BaseException:
            if log.exists():
                print(log.read_text(), flush=True)
            if output:
                output.flush()
                print(server_log.read_text(), flush=True)
            raise
        finally:
            if process is not None and process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
            if output:
                output.close()
            if pg_started:
                subprocess.run(['pg_ctl', '-D', str(database), '-m', 'immediate', '-w', 'stop'],
                               check=True, stdout=subprocess.DEVNULL)


if __name__ == '__main__':
    main()
