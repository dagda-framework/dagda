#!/usr/bin/env python3
"""Paced, bounded M0 load test. Default: 30 seconds warmup + 30 minutes measurement."""
import argparse
import collections
import concurrent.futures
import csv
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import statistics
import subprocess
import threading
import time
from support import ROOT, RuntimeFixture, process_sample


class Histogram:
    """Bounded 1 ms buckets; quantiles are bucket upper bounds, not exact samples."""
    def __init__(self):
        self.buckets = collections.Counter()
        self.count = 0
        self.maximum_ms = 0.0

    def add(self, seconds):
        milliseconds = max(0.0, seconds * 1000)
        self.buckets[min(60000, math.ceil(milliseconds))] += 1
        self.count += 1
        self.maximum_ms = max(self.maximum_ms, milliseconds)

    def percentile(self, percent):
        rank = max(1, math.ceil(self.count * percent / 100))
        cumulative = 0
        for value, count in sorted(self.buckets.items()):
            cumulative += count
            if cumulative >= rank:
                return value
        return None

    def report(self):
        return {'count': self.count, 'p50_ms': self.percentile(50), 'p95_ms': self.percentile(95),
                'p99_ms': self.percentile(99), 'max_ms': round(self.maximum_ms, 3),
                'bucket_width_ms': 1, 'overflow_bucket_ms': 60000,
                'buckets_ms': dict(sorted(self.buckets.items()))}


class Statistics:
    def __init__(self):
        self.lock = threading.Lock()
        self.completed = 0
        self.successful = 0
        self.skipped = collections.Counter()
        self.statuses = collections.Counter()
        self.errors = collections.Counter()
        self.routes = {name: {'scheduled': Histogram(), 'service': Histogram()} for name in ('json', 'lookup')}

    def skip(self, reason, count=1):
        with self.lock:
            self.skipped[reason] += count

    def record(self, route, status, error, scheduled, service):
        with self.lock:
            self.completed += 1
            self.successful += error is None
            self.statuses[str(status)] += 1
            if error:
                self.errors[error] += 1
            self.routes[route]['scheduled'].add(scheduled)
            self.routes[route]['service'].add(service)

    def report(self, elapsed, offered):
        with self.lock:
            failed = self.completed - self.successful + sum(self.skipped.values())
            return {'offered': offered, 'completed': self.completed, 'successful': self.successful,
                    'elapsed_seconds': elapsed, 'completed_rps': self.completed / elapsed,
                    'successful_rps': self.successful / elapsed,
                    'error_rate': failed / offered if offered else 0,
                    'client_skipped': dict(self.skipped), 'statuses': dict(self.statuses), 'errors': dict(self.errors),
                    'latency': {route: {kind: histogram.report() for kind, histogram in values.items()}
                                for route, values in self.routes.items()}}


def memory_trend(samples):
    """Compare early/late medians and fit the last half to reduce warmup influence."""
    if len(samples) < 4:
        return None
    window = max(1, len(samples) // 5)
    early = statistics.median(row['rss_kib'] for row in samples[:window])
    late = statistics.median(row['rss_kib'] for row in samples[-window:])
    tail = samples[len(samples) // 2:]
    x = [row['elapsed_seconds'] / 60 for row in tail]
    y = [row['rss_kib'] / 1024 for row in tail]
    mean_x, mean_y = statistics.mean(x), statistics.mean(y)
    denominator = sum((value - mean_x) ** 2 for value in x)
    slope = sum((a - mean_x) * (b - mean_y) for a, b in zip(x, y)) / denominator if denominator else 0
    return {'early_median_mib': early / 1024, 'late_median_mib': late / 1024,
            'growth_mib': (late - early) / 1024, 'late_slope_mib_per_minute': slope,
            'peak_mib': max(row['rss_kib'] for row in samples) / 1024,
            'fd_growth': statistics.median(row['fds'] for row in samples[-window:]) -
                         statistics.median(row['fds'] for row in samples[:window])}


def run_phase(fixture, name, duration, rate, concurrency, sample_interval):
    stats = Statistics()
    slots = threading.BoundedSemaphore(concurrency)
    stop = threading.Event()
    samples = []
    monitor_errors = collections.Counter()
    start = time.monotonic()
    offered = math.ceil(duration * rate)
    csv_path = fixture.artifacts / f'{name}-resources.csv'

    def measure():
        with csv_path.open('w', newline='') as output:
            writer = csv.DictWriter(output, fieldnames=['elapsed_seconds', 'rss_kib', 'virtual_kib', 'threads', 'fds', 'inflight'])
            writer.writeheader()
            while not stop.is_set():
                try:
                    row = dict(elapsed_seconds=round(time.monotonic() - start, 3),
                               **process_sample(fixture.process.pid), inflight=fixture.inflight())
                    samples.append(row)
                    writer.writerow(row)
                    output.flush()
                except Exception as error:
                    monitor_errors[type(error).__name__ + ': ' + str(error)[:160]] += 1
                stop.wait(sample_interval)

    def send(index, scheduled):
        began = time.monotonic()
        route = 'json' if index % 2 == 0 else 'lookup'
        item = 1 + (index // 2) % 2
        path = '/health/live' if route == 'json' else f'/items?id={item}'
        expected = {'status': 'ok'} if route == 'json' else {'id': item, 'name': 'Dagda' if item == 1 else 'Odin'}
        status = 'transport_error'
        error = None
        try:
            status, body, _ = fixture.request(path)
            if status != 200:
                error = f'http_{status}'
            elif body != expected:
                error = 'unexpected_response'
        except Exception as exception:
            error = type(exception).__name__
        finally:
            ended = time.monotonic()
            stats.record(route, status, error, ended - scheduled, ended - began)
            slots.release()

    monitor = threading.Thread(target=measure, daemon=True)
    monitor.start()
    next_progress = start + 30
    try:
        with concurrent.futures.ThreadPoolExecutor(max_workers=concurrency) as executor:
            index = 0
            while index < offered:
                fixture.assert_alive()
                scheduled = start + index / rate
                delay = scheduled - time.monotonic()
                if delay > 0:
                    time.sleep(delay)
                # Do not hide generator stalls by sending a catch-up burst.
                missed = min(offered - index, max(0, math.floor((time.monotonic() - scheduled) * rate)))
                if missed:
                    stats.skip('scheduler_late', missed)
                    index += missed
                    continue
                if slots.acquire(blocking=False):
                    executor.submit(send, index, scheduled)
                else:
                    stats.skip('client_capacity')
                index += 1
                if time.monotonic() >= next_progress:
                    latest = samples[-1] if samples else {}
                    snapshot = {'phase': name, 'target_seconds': duration, 'resources': latest,
                                **stats.report(time.monotonic() - start, index)}
                    temporary = fixture.artifacts / 'progress.json.tmp'
                    temporary.write_text(json.dumps(snapshot, indent=2) + '\n')
                    temporary.replace(fixture.artifacts / 'progress.json')
                    print(f'{name}: {time.monotonic() - start:.0f}/{duration:g}s, '
                          f'completed={stats.completed}, errors={sum(stats.errors.values())}, '
                          f'RSS={latest.get("rss_kib", 0) / 1024:.1f} MiB', flush=True)
                    next_progress += 30
            # Preserve the full measurement window even when the final reply is fast.
            remaining = start + duration - time.monotonic()
            if remaining > 0:
                time.sleep(remaining)
    finally:
        stop.set()
        monitor.join(timeout=6)
    elapsed = time.monotonic() - start
    fixture.assert_alive()
    result = stats.report(elapsed, offered)
    result['memory'] = memory_trend(samples)
    result['samples'] = len(samples)
    result['monitor_errors'] = dict(monitor_errors)
    result['peak_inflight'] = max((row['inflight'] for row in samples), default=0)
    result['thread_counts'] = sorted({row['threads'] for row in samples})
    (fixture.artifacts / f'{name}.json').write_text(json.dumps(result, indent=2) + '\n')
    return result


def metadata(fixture, args):
    def output(command):
        return subprocess.check_output(command, cwd=ROOT, text=True).strip()
    cpu = next((line.split(':', 1)[1].strip() for line in Path('/proc/cpuinfo').read_text().splitlines()
                if line.startswith('model name')), platform.machine())
    return {'platform': platform.platform(), 'cpu_model': cpu, 'logical_cpus': os.cpu_count(),
            'memory_total': next(line for line in Path('/proc/meminfo').read_text().splitlines() if line.startswith('MemTotal:')),
            'compiler': output(['./scripts/odin.sh', 'version']), 'postgres': fixture.sql('SELECT version()'),
            'git_commit': output(['git', 'rev-parse', 'HEAD']),
            'git_dirty': bool(output(['git', 'status', '--porcelain'])),
            'binary_sha256': hashlib.sha256(fixture.binary.read_bytes()).hexdigest(),
            'settings': vars(args), 'workload': '50% small JSON, 50% indexed PostgreSQL lookup; new HTTP connection per request',
            'timing': 'scheduled latency includes generator scheduling delay; service latency starts in the client worker',
            'resources': 'server process only; excludes PostgreSQL and Python load generator'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--duration', type=float, default=1800)
    parser.add_argument('--warmup', type=float, default=30)
    parser.add_argument('--rate', type=float, default=40, help='total offered requests/second across both routes')
    parser.add_argument('--concurrency', type=int, default=8, help='maximum outstanding client requests; no unbounded queue')
    parser.add_argument('--sample-interval', type=float, default=5)
    parser.add_argument('--max-growth-mib', type=float, default=8)
    parser.add_argument('--max-slope-mib-per-minute', type=float, default=0.25)
    parser.add_argument('--output', help='new artifact directory; defaults to a timestamp under build/runtime-checks')
    args = parser.parse_args()
    numeric = (args.duration, args.warmup, args.rate, args.sample_interval, args.max_growth_mib, args.max_slope_mib_per_minute)
    if not all(math.isfinite(value) and value > 0 for value in numeric) or not 1 <= args.concurrency <= 64:
        parser.error('durations, rate, intervals and thresholds must be finite and positive; concurrency must be 1..64')
    with RuntimeFixture(artifacts=args.output) as fixture:
        meta = metadata(fixture, args)
        (fixture.artifacts / 'metadata.json').write_text(json.dumps(meta, indent=2) + '\n')
        print(f'Warmup {args.warmup:g}s, then measurement {args.duration:g}s at {args.rate:g} requests/s', flush=True)
        warmup = run_phase(fixture, 'warmup', args.warmup, args.rate, args.concurrency, args.sample_interval)
        measured = run_phase(fixture, 'measurement', args.duration, args.rate, args.concurrency, args.sample_interval)
        time.sleep(2)
        fixture.assert_alive()
        assert fixture.inflight() == 0
        idle = process_sample(fixture.process.pid)
        trend = measured['memory']
        qualified = args.duration >= 1800 and args.warmup >= 30
        checks = {
            'no_request_errors_or_client_drops': measured['error_rate'] == 0 and warmup['error_rate'] == 0,
            'monitor_succeeded': not measured['monitor_errors'] and not warmup['monitor_errors'],
            'admission_bounded': measured['peak_inflight'] <= 8,
            'stable_thread_count': len(measured['thread_counts']) == 1,
            'memory_samples_sufficient': trend is not None,
            'rss_growth_within_budget': trend is not None and trend['growth_mib'] <= args.max_growth_mib,
            'file_descriptors_bounded': trend is not None and trend['fd_growth'] <= 4,
        }
        if qualified:
            checks['late_rss_slope_within_budget'] = trend is not None and trend['late_slope_mib_per_minute'] <= args.max_slope_mib_per_minute
        result = {'passed': all(checks.values()), 'full_duration': qualified, 'checks': checks,
                  'deferred_checks': [] if qualified else ['30-minute duration and late RSS slope'],
                  'warmup': warmup, 'measurement': measured, 'idle_after_drain': idle, 'metadata': meta}
        (fixture.artifacts / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
        for route, values in measured['latency'].items():
            latency = values['scheduled']
            print(f'{route}: p50={latency["p50_ms"]} ms p95={latency["p95_ms"]} ms p99={latency["p99_ms"]} ms', flush=True)
        print(f'Throughput {measured["successful_rps"]:.2f} successful requests/s; '
              f'error rate {measured["error_rate"]:.3%}; memory={trend}', flush=True)
        print(('PASS' if result['passed'] else 'FAIL') + (' 30-minute load gate' if qualified else ' short smoke run (not the 30-minute gate)'), flush=True)
        print(f'Result: {fixture.artifacts / "result.json"}', flush=True)
        if not result['passed']:
            raise SystemExit('Failed checks: ' + ', '.join(key for key, passed in checks.items() if not passed))


if __name__ == '__main__':
    main()
