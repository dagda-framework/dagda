#!/usr/bin/env python3
"""Typed JSON and bounded async body transport; isolated disposable database."""
import concurrent.futures
import http.client
import json
import signal
import socket
import time
from support import ROOT, RuntimeFixture, process_sample


def wire_response(connection):
    response = http.client.HTTPResponse(connection)
    response.begin()
    payload = response.read()
    # Framing errors can be rejected by the transport before the JSON handler.
    return response.status, json.loads(payload) if payload else None, dict(response.getheaders())


def main():
    with RuntimeFixture(binary=ROOT / 'build/dagda-api', environment={'DAGDA_ENV': 'test'}) as fixture:
        def post(payload, expected=200, media='application/json'):
            body = payload if isinstance(payload, bytes) else json.dumps(payload).encode()
            headers = {'Content-Type': media} if media else {}
            status, result, received = fixture.request('/echo', method='POST', body=body, headers=headers)
            assert status == expected, (body[:100], status, result)
            assert received['content-type'] == 'application/json'
            assert received['x-request-id']
            return result

        dto = {'name': 'Dagda ☘\n"', 'count': 2147483647, 'enabled': True,
               'labels': ['one', 'two'], 'note': 'optional'}
        assert post(dto) == dto
        assert post({}, media='Application/JSON; charset="UTF-8"') == {
            'name': '', 'count': 0, 'enabled': False, 'labels': [], 'note': None}
        assert post({'note': None})['note'] is None
        for payload in (b'', b'null', b'[]', b'{} {}', b'{"count":1,}', b'{count:1}',
                        b'{"count":1,"count":2}', b'{"count":2147483648}', b'{"count":-2147483649}',
                        b'{"count":1.0}', b'{"count":"1"}', b'{"name":null}', b'{"unknown":1}',
                        b'{"labels":[false]}', b'{"count":1e999}', b'{"name":"\xff"}', b'[' * 33 + b']' * 33):
            post(payload, 400)
        for media in (None, 'text/plain', 'application/json; charset=latin1'):
            post({}, 415, media)
        post(b' ' * 8193, 413)
        # An input at the exact byte limit succeeds if its encoded response fits.
        post(b'{}' + b' ' * 8190)
        # Input fits but default fields make its encoded response exceed the cap.
        post({'name': 'x' * 8150}, 500)
        print('PASS typed JSON round trips, defaults, types/ranges, strict syntax, media and exact body/response limits', flush=True)

        for headers, expected in (
            (b'Content-Length: 999999999999999999999999999\r\n', 400),
            (b'Content-Length: 8193\r\n', 413),
            (b'Content-Length: +2\r\n', 400),
            (b'Content-Length: -1\r\n', 400),
            (b'Content-Length: 2\r\nExpect: 100-continue\r\n', 417),
            (b'Content-Length: 2\r\nContent-Encoding: gzip\r\n', 415),
            (b'Transfer-Encoding: chunked\r\n', 400),
            (b'Content-Length: 2\r\nTransfer-Encoding: chunked\r\n', 400),
            (b'Content-Length: 2\r\nContent-Length: 2\r\n', 400),
        ):
            with fixture.connect() as raw:
                raw.sendall(b'POST /echo HTTP/1.1\r\nHost: localhost\r\n' + headers + b'\r\n')
                status, _, _ = wire_response(raw)
                assert status == expected, (headers, status)
        print('PASS body framing, unsupported encodings and Expect rejected before reading payload', flush=True)

        encoded = json.dumps(dto).encode()
        prefix = (f'POST /echo HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nContent-Length: {len(encoded)}\r\n\r\n').encode()
        with fixture.connect() as raw:
            raw.sendall(prefix + encoded[:1])
            assert fixture.request('/health/live')[0] == 200
            for offset in range(1, len(encoded), 7):
                raw.sendall(encoded[offset:offset+7])
                time.sleep(0.003)
            assert wire_response(raw)[:2] == (200, dto)
        with fixture.connect() as raw:
            raw.sendall(prefix + b'{')
            raw.shutdown(socket.SHUT_WR)
            assert wire_response(raw)[0] == 400
        with fixture.connect() as raw:
            raw.sendall(prefix + b'{')
            start = time.monotonic()
            assert fixture.request('/health/live')[0] == 200
            assert wire_response(raw)[0] == 400
            assert time.monotonic() - start < 3.5
        print('PASS fragmented/half-closed/timed-out bodies keep liveness responsive and expire within bounds', flush=True)

        time.sleep(0.7)
        before = process_sample(fixture.process.pid)
        for _ in range(80):
            with fixture.connect() as raw:
                raw.sendall(prefix + b'{')
            time.sleep(0.025)
        time.sleep(0.7)
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as executor:
            results = list(executor.map(lambda _: post(dto), range(24)))
        assert all(result == dto for result in results)
        time.sleep(0.7)
        after = process_sample(fixture.process.pid)
        assert after['threads'] == before['threads']
        assert after['fds'] <= before['fds'] + 2, (before, after)
        assert after['rss_kib'] <= before['rss_kib'] + 8192, (before, after)
        assert 'Dagda ☘' not in fixture.server_log.read_text()
        print('PASS interrupted uploads and concurrent typed requests preserve ownership and bounded resources', flush=True)

        with fixture.connect() as raw:
            raw.sendall(prefix + b'{')
            time.sleep(0.05)
            fixture.process.send_signal(signal.SIGTERM)
            fixture.process.wait(timeout=5)
        assert fixture.process.returncode == 0
        record = {'passed': True, 'suite': 'M1 typed JSON', 'before': before, 'after': after}
        (fixture.artifacts / 'result.json').write_text(json.dumps(record, indent=2) + '\n')
        print('PASS SIGTERM drains an incomplete body without hanging or crashing', flush=True)


if __name__ == '__main__':
    main()
