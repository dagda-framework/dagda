#!/usr/bin/env python3
"""M1 lifecycle, routing, middleware, readiness and access-log integration checks."""
import concurrent.futures
from contextlib import closing
import http.client
import json
import re
import signal
import socket
import subprocess
import time
from support import ROOT, RuntimeFixture, process_sample, wait_until


def records(fixture):
    result = []
    for line in fixture.server_log.read_text().splitlines():
        if line.startswith('{'):
            result.append(json.loads(line))
    return result


def main():
    with RuntimeFixture(binary=ROOT / 'build/dagda-api', environment={'DAGDA_ENV': 'test', 'DAGDA_ACCESS_LOG': 'true'}) as fixture:
        observed = {}
        def check(path, expected_status, expected_body=None, **kwargs):
            status, body, headers = fixture.request(path, **kwargs)
            assert status == expected_status, (path, status, body)
            if expected_body is not None:
                assert body == expected_body, (path, body)
            request_id = headers['x-request-id']
            assert re.fullmatch(r'[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}', request_id), request_id
            assert request_id not in observed
            observed[request_id] = status
            if status >= 400:
                assert body['request_id'] == request_id, body
                assert body['error']['code'] and body['error']['message'], body
            return body, headers

        check('/', 200, {'name': 'Dagda'})
        check('/health/live', 200, {'status': 'ok'})
        check('/health/ready', 200, {'status': 'ready'})
        _, headers = check('/items/1', 200, {'id': 1, 'name': 'Dagda'})
        assert headers['x-powered-by'] == 'Dagda'
        check('/items/%32', 200, {'id': 2, 'name': 'Odin'})
        check('/items/new', 200, {'route': 'static'})
        check('/items/not-an-id', 400)
        check('/items/999', 404)
        check('/missing?secret=DO_NOT_LOG', 404)
        check('/items/1/', 404)
        _, headers = check('/items/1', 405, method='DELETE')
        assert headers['allow'] == 'GET'
        check('/items', 501, method='POST')
        for path in ('/items/%2fadmin', '/items/%5cadmin', '/items/%2e%2e', '/items/%zz', '/items//1'):
            check(path, 400)
        print('PASS route parameters, decoding, static precedence, 404/405/Allow and explicit methods', flush=True)

        check('/private', 401)
        check('/private', 200, {'name': 'Dagda'}, headers={'X-Demo-Key': 'example', 'Authorization': 'DO_NOT_LOG'})
        _, headers = check('/', 200, headers={'X-Request-ID': 'untrusted-client-value'})
        assert headers['x-request-id'] != 'untrusted-client-value'
        with closing(http.client.HTTPConnection('127.0.0.1', fixture.port, timeout=3)) as connection:
            connection.request('HEAD', '/')
            response = connection.getresponse()
            assert response.status == 200 and response.read() == b''
            assert int(response.getheader('content-length')) == len('{"name":"Dagda"}')
        print('PASS global/route middleware, short-circuit response, generated request IDs and HEAD', flush=True)

        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as executor:
            replies = list(executor.map(lambda i: fixture.request(f'/items/{1 + i % 2}'), range(24)))
        assert all(status == 200 and body['id'] in (1, 2) for status, body, _ in replies)
        ids = [headers['x-request-id'] for _, _, headers in replies]
        assert len(set(ids)) == len(ids)
        time.sleep(0.7)  # Let the bounded transport close-grace timers finish.
        baseline = process_sample(fixture.process.pid)
        for index in range(120):
            item = 1 + index % 2
            check(f'/items/{item}', 200, {'id': item, 'name': 'Dagda' if item == 1 else 'Odin'})
            time.sleep(0.025)
        time.sleep(0.7)
        after_reuse = process_sample(fixture.process.pid)
        assert after_reuse['fds'] <= baseline['fds'] + 2, (baseline, after_reuse)
        assert after_reuse['threads'] == baseline['threads'], (baseline, after_reuse)
        assert after_reuse['rss_kib'] <= baseline['rss_kib'] + 8192, (baseline, after_reuse)
        print('PASS repeated request-context/worker reuse preserves response bytes and bounded resources', flush=True)

        body, _ = check('/_test/sql-error', 500)
        assert body['error'] == {'code': 'query_failed', 'message': 'Internal server error'}
        body, _ = check('/_test/slow?ms=2000', 503)
        assert body['error']['code'] == 'deadline_exceeded'
        fixture.stop_database()
        check('/health/live', 200, {'status': 'ok'})
        body, _ = check('/health/ready', 503)
        assert body['error']['code'] == 'not_ready'
        body, _ = check('/items/1', 503)
        assert body['error']['code'] == 'database_unavailable'
        fixture.start_database()
        wait_until(lambda: fixture.request('/health/ready')[:2] == (200, {'status': 'ready'}))
        check('/items/1', 200, {'id': 1, 'name': 'Dagda'})
        print('PASS readiness fails during database outage and recovers; liveness remains available', flush=True)

        # Transport-level rejection must have an ID and one access record too.
        with fixture.connect() as raw:
            raw.sendall(b'GET /items/1 HTTP/1.1\r\nHost: localhost\r\nBad(Name): DO_NOT_LOG\r\n\r\n')
            connection_file = raw.makefile('rb')
            response_line = connection_file.readline()
            assert b' 400 ' in response_line
            wire_headers = {}
            for line in connection_file:
                if line == b'\r\n':
                    break
                key, value = line.decode().split(':', 1)
                wire_headers[key.lower()] = value.strip()
            observed[wire_headers['x-request-id']] = 400
            connection_file.close()
        with fixture.connect() as raw:
            raw.sendall(b'GET /DO_NOT_LOG HTTP/nope\r\nHost: localhost\r\n\r\n')
            assert raw.recv(1024) == b''
        with fixture.connect() as partial:
            partial.sendall(b'GET / HTTP/1.1\r\nHost:')
            assert partial.recv(1024) == b''
        time.sleep(0.2)
        access = [entry for entry in records(fixture) if entry['event'] == 'access']
        for request_id, status in observed.items():
            matching = [entry for entry in access if entry['request_id'] == request_id]
            assert len(matching) == 1 and matching[0]['status'] == status, (request_id, matching)
        assert any(entry['status'] == 0 and entry['outcome'] == 'connection_closed' for entry in access)
        assert any(entry['route'] == '/items/:id' and entry['status'] == 200 for entry in access)
        assert 'DO_NOT_LOG' not in fixture.server_log.read_text()
        assert 'password=' not in fixture.server_log.read_text()
        print('PASS one structured access record per completion, including malformed/incomplete requests; secrets omitted', flush=True)

        # Independent processes prove configuration/startup failures are nonzero
        # without taking ownership of or stopping an existing service.
        for override in (
            {'DAGDA_DEADLINE_MS': 'invalid'},
            {'DAGDA_DATABASE_URL': 'host=remote password=DO_NOT_LOG'},
            {'DAGDA_DATABASE_URL': 'host=/tmp/dagda-no-such-socket password=DO_NOT_LOG dbname=missing'},
            {'DAGDA_LISTEN': f'127.0.0.1:{fixture.port}'},
        ):
            env = dict(fixture.env, DAGDA_DATABASE_URL=fixture.conninfo, DAGDA_DEADLINE_MS='500')
            env.update(override)
            result = subprocess.run([str(fixture.binary)], env=env, capture_output=True, text=True, timeout=5)
            assert result.returncode != 0, override
            assert 'DO_NOT_LOG' not in result.stdout + result.stderr
        print('PASS invalid configuration, unavailable startup database, and occupied listener fail without exposing secrets', flush=True)

        env = dict(fixture.env, DAGDA_DATABASE_URL=fixture.conninfo, DAGDA_ENV='test', DAGDA_TEST_START_FAIL='1')
        failed = subprocess.run([str(fixture.binary)], env=env, capture_output=True, text=True, timeout=5)
        assert failed.returncode != 0
        assert failed.stdout.count('example_start') == failed.stdout.count('example_stop') == 1
        assert 'listening' not in failed.stderr

        with concurrent.futures.ThreadPoolExecutor(max_workers=3) as executor:
            active = [executor.submit(fixture.request, '/_test/slow?ms=250') for _ in range(3)]
            wait_until(lambda: fixture.sql("SELECT count(*) FROM pg_stat_activity WHERE application_name='dagda-m0' AND state='active'") == '2')
            with fixture.connect() as partial:
                partial.sendall(b'GET / HTTP/1.1\r\nHost:')
                fixture.process.send_signal(signal.SIGTERM)
                assert all(future.result()[0] == 200 for future in active)
                fixture.process.wait(timeout=5)
        assert fixture.process.returncode == 0
        events = [entry['event'] for entry in records(fixture)]
        assert events.count('listening') == events.count('draining') == events.count('stopped') == 1
        assert events.count('example_start') == events.count('example_stop') == 1
        (fixture.artifacts / 'result.json').write_text(json.dumps({'passed': True, 'suite': 'M1 lifecycle and routing',
                                                                'observed_request_ids': len(observed),
                                                                'before_reuse': baseline, 'after_reuse': after_reuse}, indent=2) + '\n')
        print('PASS startup-hook failure cleans up; SIGTERM drains active queries/partial requests with hooks called once', flush=True)


if __name__ == '__main__':
    main()
