#!/usr/bin/env python3
"""Field validation and structured 422 responses against an isolated runtime."""
import concurrent.futures
import json
import time
from support import ROOT, RuntimeFixture, process_sample


def main():
    with RuntimeFixture(binary=ROOT / 'build/dagda-api', environment={'DAGDA_ENV': 'test'}) as fixture:
        observed = {}
        def post(value, expected, fields=None, media='application/json'):
            payload = value if isinstance(value, bytes) else json.dumps(value).encode()
            status, body, headers = fixture.request('/validate', method='POST', body=payload,
                                                     headers={'Content-Type': media})
            assert status == expected, (status, body)
            request_id = headers['x-request-id']
            assert request_id not in observed
            observed[request_id] = status
            if fields is not None:
                assert body == {'error': {'code': 'validation_failed', 'message': 'Request validation failed',
                                          'fields': fields}, 'request_id': request_id}, body
            return body

        valid = {'title': 'Dagda', 'quantity': 1, 'priority': 'normal', 'enabled': False}
        assert post(valid, 200) == valid
        post({}, 422, {'title': ['required'], 'quantity': ['out_of_range'],
                       'priority': ['invalid_choice'], 'enabled': ['required']})
        for title in ('', ' \t\n\u2003'):
            post(dict(valid, title=title), 422, {'title': ['required']})
        for title in ('☘' * 80, 'é' * 80, '  keep spaces  '):
            assert post(dict(valid, title=title), 200)['title'] == title
        post(dict(valid, title='☘' * 81), 422, {'title': ['too_long']})
        post(dict(valid, quantity=0), 422, {'quantity': ['out_of_range']})
        post(dict(valid, quantity=101), 422, {'quantity': ['out_of_range']})
        assert post(dict(valid, quantity=100, priority='high', enabled=True), 200)['enabled'] is True
        post(dict(valid, priority='Normal'), 422, {'priority': ['invalid_choice']})
        missing = dict(valid)
        del missing['enabled']
        post(missing, 422, {'enabled': ['required']})
        print('PASS structured 422 envelope, grouped field codes, request-ID correlation, Unicode lengths and required false boolean', flush=True)

        for value in (b'{', dict(valid, quantity='one'), dict(valid, unknown=True), dict(valid, enabled=None)):
            body = post(value, 400)
            assert body['error']['code'] == 'invalid_json', body
        assert post(valid, 415, media='text/plain')['error']['code'] == 'unsupported_media_type'
        secret = 'DO_NOT_ECHO_PRIVATE_VALUE' * 5
        body = post(dict(valid, title=secret, priority=secret), 422,
                    {'title': ['too_long'], 'priority': ['invalid_choice']})
        assert secret not in json.dumps(body)
        print('PASS malformed/types/media stay separate from business validation; submitted values omitted from errors', flush=True)

        time.sleep(0.7)
        before = process_sample(fixture.process.pid)
        invalid = dict(valid, quantity=0)
        # Each worker returns its response; the main thread checks ID uniqueness.
        def exercise(index):
            value = valid if index % 2 == 0 else invalid
            return fixture.request('/validate', method='POST', body=json.dumps(value).encode(),
                                   headers={'Content-Type': 'application/json'})
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as executor:
            results = list(executor.map(exercise, range(24)))
        for index, (status, body, headers) in enumerate(results):
            assert status == (200 if index % 2 == 0 else 422), (status, body)
            request_id = headers['x-request-id']
            assert request_id not in observed
            observed[request_id] = status
            if status == 422:
                assert body['request_id'] == request_id
                assert body['error']['fields'] == {'quantity': ['out_of_range']}
        time.sleep(0.7)
        for _ in range(80):
            post(invalid, 422, {'quantity': ['out_of_range']})
            time.sleep(0.025)
        time.sleep(0.7)
        after = process_sample(fixture.process.pid)
        assert after['threads'] == before['threads']
        assert after['fds'] <= before['fds'] + 2, (before, after)
        assert after['rss_kib'] <= before['rss_kib'] + 8192, (before, after)
        log = fixture.server_log.read_text()
        assert 'DO_NOT_ECHO_PRIVATE_VALUE' not in log
        records = [json.loads(line) for line in log.splitlines() if line.startswith('{')]
        access = [entry for entry in records if entry['event'] == 'access']
        for request_id, status in observed.items():
            matching = [entry for entry in access if entry['request_id'] == request_id]
            assert len(matching) == 1 and matching[0]['status'] == status, (request_id, matching)
            assert matching[0]['route'] == '/validate'
        result = {'passed': True, 'suite': 'M1 field validation', 'observed_request_ids': len(observed),
                  'before': before, 'after': after}
        (fixture.artifacts / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
        print('PASS concurrent/repeated validation responses preserve IDs, bounded resources and one access log each', flush=True)


if __name__ == '__main__':
    main()
