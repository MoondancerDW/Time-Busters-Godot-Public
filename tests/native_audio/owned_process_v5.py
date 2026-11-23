"""Single-mode replay v3 with a private Windows Job Object and bounded owned cleanup.
External pinned-PowerShell7 workspace/lease checks remain the caller's responsibility.
No game is started on import. The original a24... helper is historical and unchanged.
"""
import argparse
import ctypes as C
from ctypes import wintypes as W
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import time
import traceback

P = Path(r'D:\TimeBusters\port')
STILL_ACTIVE = 259
PROCESS_RIGHTS = 0x100000 | 0x1000 | 0x0001  # synchronize/query-limited/terminate


class BasicLimits(C.Structure):
    _fields_ = [('process_time', C.c_int64), ('job_time', C.c_int64),
                ('flags', W.DWORD), ('min_ws', C.c_size_t), ('max_ws', C.c_size_t),
                ('active_limit', W.DWORD), ('affinity', C.c_size_t),
                ('priority', W.DWORD), ('scheduling', W.DWORD)]


class IoCounters(C.Structure):
    _fields_ = [(n, C.c_uint64) for n in ['reads', 'writes', 'other', 'read_bytes', 'write_bytes', 'other_bytes']]


class ExtendedLimits(C.Structure):
    _fields_ = [('basic', BasicLimits), ('io', IoCounters),
                ('process_memory', C.c_size_t), ('job_memory', C.c_size_t),
                ('peak_process', C.c_size_t), ('peak_job', C.c_size_t)]


class ThreadEntry(C.Structure):
    _fields_ = [('size', W.DWORD), ('usage', W.DWORD), ('thread_id', W.DWORD),
                ('owner_pid', W.DWORD), ('base_priority', W.LONG),
                ('delta_priority', W.LONG), ('flags', W.DWORD)]


class WindowsAPI:
    def __init__(self):
        if os.name != 'nt':
            raise RuntimeError('This ownership guard requires Windows Job Objects')
        self.k = C.WinDLL('kernel32', use_last_error=True)
        definitions = {
            'CreateJobObjectW': ([C.c_void_p, W.LPCWSTR], W.HANDLE),
            'SetInformationJobObject': ([W.HANDLE, C.c_int, C.c_void_p, W.DWORD], W.BOOL),
            'QueryInformationJobObject': ([W.HANDLE, C.c_int, C.c_void_p, W.DWORD, C.POINTER(W.DWORD)], W.BOOL),
            'AssignProcessToJobObject': ([W.HANDLE, W.HANDLE], W.BOOL),
            'IsProcessInJob': ([W.HANDLE, W.HANDLE, C.POINTER(W.BOOL)], W.BOOL),
            'TerminateJobObject': ([W.HANDLE, W.UINT], W.BOOL),
            'GetProcessId': ([W.HANDLE], W.DWORD),
            'GetProcessIdOfThread': ([W.HANDLE], W.DWORD),
            'GetExitCodeProcess': ([W.HANDLE, C.POINTER(W.DWORD)], W.BOOL),
            'GetProcessTimes': ([W.HANDLE, C.POINTER(W.FILETIME), C.POINTER(W.FILETIME), C.POINTER(W.FILETIME), C.POINTER(W.FILETIME)], W.BOOL),
            'OpenProcess': ([W.DWORD, W.BOOL, W.DWORD], W.HANDLE),
            'TerminateProcess': ([W.HANDLE, W.UINT], W.BOOL),
            'WaitForSingleObject': ([W.HANDLE, W.DWORD], W.DWORD),
            'CloseHandle': ([W.HANDLE], W.BOOL),
            'CreateToolhelp32Snapshot': ([W.DWORD, W.DWORD], W.HANDLE),
            'Thread32First': ([W.HANDLE, C.POINTER(ThreadEntry)], W.BOOL),
            'Thread32Next': ([W.HANDLE, C.POINTER(ThreadEntry)], W.BOOL),
            'OpenThread': ([W.DWORD, W.BOOL, W.DWORD], W.HANDLE),
            'ResumeThread': ([W.HANDLE], W.DWORD),
            'GetCurrentProcess': ([], W.HANDLE),
            'QueryFullProcessImageNameW': ([W.HANDLE, W.DWORD, W.LPWSTR, C.POINTER(W.DWORD)], W.BOOL),
        }
        for name, (args, result) in definitions.items():
            fn = getattr(self.k, name)
            fn.argtypes, fn.restype = args, result

    def checked(self, result, operation):
        if not result:
            raise C.WinError(C.get_last_error(), operation)
        return result

    def created(self, handle):
        values = [W.FILETIME() for unused in range(4)]
        self.checked(self.k.GetProcessTimes(handle, *[C.byref(v) for v in values]), 'GetProcessTimes')
        return (int(values[0].dwHighDateTime) << 32) | int(values[0].dwLowDateTime)

    def active(self, handle):
        code = W.DWORD()
        self.checked(self.k.GetExitCodeProcess(handle, C.byref(code)), 'GetExitCodeProcess')
        # Wait result distinguishes a terminated process whose actual exit code happens to be 259.
        return self.k.WaitForSingleObject(handle, 0) == 0x102, int(code.value)


class OwnedJob:
    """An unnamed, non-inheritable job; only one verified suspended Popen is assigned."""
    def __init__(self):
        self.api = WindowsAPI()
        self.job = self.api.checked(self.api.k.CreateJobObjectW(None, None), 'CreateJobObjectW')
        self.proc = None
        self.parent_created = None
        self.assigned = False
        self.observed = {}
        self.observed_images = {}
        limits = ExtendedLimits()
        limits.basic.flags = 0x2000  # JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE; breakaway is NOT enabled.
        try:
            self.api.checked(self.api.k.SetInformationJobObject(self.job, 9, C.byref(limits), C.sizeof(limits)), 'SetInformationJobObject')
        except BaseException:
            self.api.k.CloseHandle(self.job)
            self.job = None
            raise

    def members(self):
        capacity = 256
        snapshots = []
        for attempt in range(8):
            raw = C.create_string_buffer(8 + capacity * C.sizeof(C.c_size_t))
            returned = W.DWORD()
            self.api.checked(self.api.k.QueryInformationJobObject(self.job, 3, raw, len(raw), C.byref(returned)), 'QueryInformationJobObject PID list')
            counts = (W.DWORD * 2).from_buffer(raw)
            assigned, listed = int(counts[0]), int(counts[1])
            snapshots.append({'assigned': assigned, 'listed': listed, 'returned_bytes': int(returned.value)})
            if assigned > capacity or listed > capacity:
                raise RuntimeError('Owned job exceeds bounded PID inventory: ' + json.dumps(snapshots))
            if assigned == listed:
                ids = (C.c_size_t * listed).from_buffer(raw, 8)
                return [int(pid) for pid in ids]
            # An under-cap response may be incomplete during process exit.
            # Never accept a partial list or raise the fixed inventory bound.
            if attempt < 7:
                time.sleep(0.005)
        raise RuntimeError('Owned job PID inventory did not stabilize after 8 queries: ' + json.dumps(snapshots))

    def is_member(self, handle):
        member = W.BOOL()
        self.api.checked(self.api.k.IsProcessInJob(handle, self.job, C.byref(member)), 'IsProcessInJob')
        return bool(member.value)

    def observe(self):
        ids = self.members()
        for pid in ids:
            handle = self.api.k.OpenProcess(PROCESS_RIGHTS, False, pid)
            if not handle:
                continue  # May already have exited; its PID is never killed by name or number alone.
            try:
                if self.api.k.GetProcessId(handle) != pid or not self.is_member(handle):
                    continue
                created = self.api.created(handle)
                token = (pid, created)
                if token not in self.observed:
                    if len(self.observed) >= 256:
                        raise RuntimeError('Owned process observation bound exceeded')
                    self.observed[token] = handle
                    image = C.create_unicode_buffer(32768)
                    length = W.DWORD(len(image))
                    self.observed_images[token] = image.value if self.api.k.QueryFullProcessImageNameW(handle, 0, image, C.byref(length)) else None
                    handle = None
            finally:
                if handle:
                    self.api.k.CloseHandle(handle)
        return ids

    def verified_parent_live(self):
        if self.proc is None or self.proc.poll() is not None:
            return False
        handle = int(self.proc._handle)
        active, unused = self.api.active(handle)
        if not active or self.api.k.GetProcessId(handle) != self.proc.pid:
            return False
        # A creation-time query can itself fail before assignment. The still-live original
        # retained Popen handle/PID remains sufficient for fail-closed termination of that suspended process.
        return self.parent_created is None or self.api.created(handle) == self.parent_created

    def start(self, command, *, cwd, env, log):
        # Assign before resuming the primary thread: descendants cannot race job attachment.
        self.proc = subprocess.Popen(command, cwd=cwd, env=env, stdout=log, stderr=subprocess.STDOUT,
                                     creationflags=0x4 | subprocess.CREATE_NO_WINDOW)
        self.parent_created = self.api.created(int(self.proc._handle))
        if not self.verified_parent_live():
            raise RuntimeError('Original suspended Popen ownership could not be verified')
        self.api.checked(self.api.k.AssignProcessToJobObject(self.job, int(self.proc._handle)), 'AssignProcessToJobObject')
        self.assigned = True
        self.observe()
        snapshot = self.api.k.CreateToolhelp32Snapshot(0x4, 0)  # THREAD snapshot, read-only.
        if snapshot == C.c_void_p(-1).value:
            raise C.WinError(C.get_last_error())
        try:
            entry = ThreadEntry()
            entry.size = C.sizeof(entry)
            found = []
            okay = self.api.k.Thread32First(snapshot, C.byref(entry))
            while okay:
                if entry.owner_pid == self.proc.pid:
                    found.append(int(entry.thread_id))
                okay = self.api.k.Thread32Next(snapshot, C.byref(entry))
            if len(found) != 1:
                raise RuntimeError('Suspended Popen does not have exactly one owned primary thread')
            thread = self.api.checked(self.api.k.OpenThread(0x42, False, found[0]), 'OpenThread')
            try:
                if self.api.k.GetProcessIdOfThread(thread) != self.proc.pid or not self.verified_parent_live():
                    raise RuntimeError('Primary thread/Popen ownership mismatch before resume')
                previous = self.api.k.ResumeThread(thread)
                if previous != 1:
                    raise RuntimeError('Unexpected primary-thread suspend count: ' + str(previous))
            finally:
                self.api.k.CloseHandle(thread)
        finally:
            self.api.k.CloseHandle(snapshot)
        return self.proc

    def cleanup(self, reason):
        report = {'reason': reason, 'original_Popen_PID': self.proc.pid if self.proc else None,
                  'original_parent_verified_live_before_tree_termination': False,
                  'termination_requested_PID_tokens': [], 'termination_attempts': [], 'errors': [], 'remaining_owned_PIDs': [],
                  'zero_own_processes_verified': False, 'job_handle_closed': False}
        try:
            before = self.observe()
            report['owned_members_before'] = before
            parent_live = self.verified_parent_live()
            # A console launcher may exit just before its owned conhost does. Give only
            # normal-exit descendants a bounded natural exit; timeout/error cleanup is unchanged.
            if (reason == 'normal_exit' and self.assigned and self.proc is not None
                    and not parent_live and self.api.k.WaitForSingleObject(int(self.proc._handle), 0) == 0):
                grace_start = time.monotonic()
                grace_deadline = grace_start + 2.0
                while True:
                    grace_members = self.observe()
                    grace_active = [pid for (pid, created), handle in self.observed.items() if self.api.active(handle)[0]]
                    if (not grace_members and not grace_active) or time.monotonic() >= grace_deadline:
                        break
                    time.sleep(0.01)
                report['natural_exit_grace'] = {'limit_seconds': 2.0, 'elapsed_seconds': time.monotonic()-grace_start,
                                               'original_retained_handle_signaled': True,
                                               'remaining_job_members': grace_members, 'active_retained_PIDs': grace_active,
                                               'completed': not grace_members and not grace_active}
                parent_live = self.verified_parent_live()
            report['original_parent_verified_live_before_tree_termination'] = parent_live
            if parent_live and self.is_member(int(self.proc._handle)):
                targets = [{'pid': pid, 'created': created} for (pid, created), handle in self.observed.items() if self.api.active(handle)[0] and self.is_member(handle)]
                report['termination_attempts'].append({'api': 'TerminateJobObject', 'verified_PID_tokens': targets})
                self.api.checked(self.api.k.TerminateJobObject(self.job, 0xE0000001), 'TerminateJobObject')
                report['termination_scope'] = 'private unnamed job; verified original Popen live/member'
                report['termination_requested_PID_tokens'] = targets
                report['termination_record_semantics'] = 'Verified active own members immediately before request; concurrently natural exits are not separately attributed.'
            else:
                # Original parent exited, or failed assignment while still suspended. Never taskkill a stale PID.
                report['termination_scope'] = 'verified individual retained handles; no stale-parent tree kill'
                if parent_live and not self.is_member(int(self.proc._handle)):
                    report['termination_attempts'].append({'api': 'TerminateProcess', 'pid': self.proc.pid, 'created': self.parent_created, 'retained_original_handle': True})
                    self.api.checked(self.api.k.TerminateProcess(int(self.proc._handle), 0xE0000001), 'TerminateProcess suspended original')
                    report['termination_requested_PID_tokens'].append({'pid': self.proc.pid, 'created': self.parent_created})
                for (pid, created), handle in self.observed.items():
                    active, unused = self.api.active(handle)
                    if active and self.api.k.GetProcessId(handle) == pid and self.api.created(handle) == created and self.is_member(handle):
                        report['termination_attempts'].append({'api': 'TerminateProcess', 'pid': pid, 'created': created, 'verified_private_job_member': True})
                        self.api.checked(self.api.k.TerminateProcess(handle, 0xE0000001), 'TerminateProcess verified descendant')
                        report['termination_requested_PID_tokens'].append({'pid': pid, 'created': created})
            deadline = time.monotonic() + 2.0
            while True:
                remaining = self.observe()
                active_handles = [pid for (pid, created), handle in self.observed.items() if self.api.active(handle)[0]]
                if (not remaining and not active_handles) or time.monotonic() >= deadline:
                    break
                time.sleep(0.01)
            if self.proc is not None:
                self.proc.wait(timeout=2)
            report['remaining_owned_PIDs'] = remaining
        except BaseException as exc:
            report['errors'].append(type(exc).__name__ + ': ' + str(exc))
        finally:
            # The retained Popen handle identifies the exact created kernel process object.
            # Cleanup must NOT depend on a repeated PID lookup or created()/metadata read.
            report['assigned_to_private_job'] = self.assigned
            original_handle = int(self.proc._handle) if self.proc is not None else None
            original_exited = original_handle is None
            if original_handle is not None:
                try:
                    state_before = self.api.k.WaitForSingleObject(original_handle, 0)
                    report['original_handle_wait_before_finally'] = int(state_before)
                    if state_before != 0:  # Not signaled (or query error): exact retained handle only.
                        report['termination_attempts'].append({'api': 'TerminateProcess', 'pid': self.proc.pid, 'created': self.parent_created, 'retained_original_handle': True})
                        self.api.checked(self.api.k.TerminateProcess(original_handle, 0xE0000001), 'TerminateProcess exact original retained handle')
                        report['original_handle_termination_requested'] = True
                except BaseException as exc:
                    report['errors'].append('original retained-handle termination: ' + str(exc))
                # Independent bounded verification still executes if the preceding request errored.
                try:
                    original_exited = self.api.k.WaitForSingleObject(original_handle, 2000) == 0
                    report['original_handle_exit_verified'] = original_exited
                    self.proc.poll()  # Exit status only; no creation-time/PID metadata lookup.
                except BaseException as exc:
                    report['errors'].append('original retained-handle wait: ' + str(exc))
            if not self.assigned:
                # Before assignment the original was never resumed, so no descendant can exist.
                try:
                    remaining = self.members()  # Kernel job inventory, not process metadata.
                    report['remaining_owned_PIDs'] = remaining
                    report['zero_own_processes_verified'] = original_exited and not remaining
                    report['unassigned_cleanup_basis'] = 'exact retained original handle signaled + empty never-assigned job'
                except BaseException as exc:
                    report['errors'].append('unassigned empty-job verification: ' + str(exc))
            # Always serialize retained-handle outcomes, even when a cleanup request errored.
            # An API error remains an error; a now-empty job does not turn that case into a pass.
            final_members = None
            try:
                final_members = self.observe()
                report['remaining_owned_PIDs'] = final_members
            except BaseException as exc:
                report['errors'].append('final owned inventory: ' + type(exc).__name__ + ': ' + str(exc))
            report['observed_exit_codes'] = []
            all_exited = True
            for (pid, created), handle in self.observed.items():
                row = {'pid': pid, 'created': created, 'image': self.observed_images.get((pid, created))}
                try:
                    active, code = self.api.active(handle)
                    row.update(active=active, OS_exit_code=code)
                    all_exited = all_exited and not active
                except BaseException as exc:
                    all_exited = False
                    row.update(active=None, OS_exit_code=None, error=type(exc).__name__ + ': ' + str(exc))
                    report['errors'].append('retained exit row: ' + str(pid) + ': ' + row['error'])
                report['observed_exit_codes'].append(row)
            report['zero_own_processes_verified'] = original_exited and final_members is not None and not final_members and all_exited
            # This last handle is never inherited. Owner death or any error still closes only this private job.
            if self.job:
                self.api.k.CloseHandle(self.job)
                self.job = None
                report['job_handle_closed'] = True
            for handle in self.observed.values():
                self.api.k.CloseHandle(handle)
            self.observed.clear()
            self.observed_images.clear()
        return report


def run_owned(command, *, cwd, env, log_path, timeout):
    job = None
    result = {'command': command, 'console_launcher_PID': None, 'OS_exit_code': None,
              'timed_out': False, 'interrupted': False, 'error': None, 'passed': False,
              'observed_owned_PIDs': [], 'containment': 'suspended original assigned to private non-breakaway kill-on-close job before resume'}
    start = time.monotonic()
    try:
        job = OwnedJob()
        with Path(log_path).open('wb') as log:
            proc = job.start(command, cwd=cwd, env=env, log=log)
            result['console_launcher_PID'] = proc.pid
            print(json.dumps({'console_launcher_PID': proc.pid, 'private_job_assigned_before_resume': True}), flush=True)
            deadline = start + timeout
            while proc.poll() is None:
                job.observe()
                if time.monotonic() >= deadline:
                    raise subprocess.TimeoutExpired(command, timeout)
                time.sleep(0.02)
            job.observe()
            result['OS_exit_code'] = proc.wait(timeout=0)
    except BaseException as exc:
        result['timed_out'] = isinstance(exc, subprocess.TimeoutExpired)
        result['interrupted'] = isinstance(exc, (KeyboardInterrupt, SystemExit))
        result['error'] = {'type': type(exc).__name__, 'message': str(exc), 'traceback': traceback.format_exc()}
    finally:
        result['observed_owned_PIDs'] = sorted({pid for pid, created in job.observed}) if job else []
        result['observed_owned_processes'] = [{'pid': pid, 'created': created, 'image': job.observed_images.get((pid, created))} for pid, created in job.observed] if job else []
        result['cleanup'] = job.cleanup('timeout' if result['timed_out'] else 'interruption' if result['interrupted'] else 'exception' if result['error'] else 'normal_exit') if job else {'not_started': True, 'zero_own_processes_verified': True, 'termination_requested_PID_tokens': [], 'errors': [], 'remaining_owned_PIDs': []}
        if job is not None and job.proc is not None:
            result['OS_exit_code'] = job.proc.returncode
        result['elapsed_seconds'] = time.monotonic() - start
        result['passed'] = bool(not result['error'] and result['timed_out'] is False and result['interrupted'] is False
                                and result['OS_exit_code'] == 0 and result['cleanup']['zero_own_processes_verified']
                                and not result['cleanup']['errors'] and not result['cleanup']['termination_requested_PID_tokens']
                                and not result['cleanup'].get('termination_attempts', []))
    return result


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--mode', choices=['create', 'resume'], required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--project', type=Path, default=P / 'godot')
    args = parser.parse_args()
    output = args.output.resolve()
    assert output.is_relative_to(P / '.local/R28')
    if args.mode == 'create':
        assert not output.exists()
        (output / 'progress').mkdir(parents=True)
        shutil.copyfile(P / '.local/R08/accepted-r16/saves/gear8-RU.json', output / 'progress/slot1.json')
    else:
        assert (output / 'progress/slot1.json').exists() and (output / 'create.json').exists()
    runtime_path = output / (args.mode + '.json')
    command_path = output / (args.mode + '-command.json')
    log_path = output / (args.mode + '.log')
    assert not any(path.exists() for path in [runtime_path, command_path, log_path])
    env = dict(os.environ, TIMEBUSTERS_SAVE_DIRECTORY=str(output / 'progress'), R24_MODE=args.mode,
               R24_ORIGINAL=str(output / 'progress/slot1.json'), R24_OUTPUT=str(runtime_path))
    command = [env['TIMEBUSTERS_GODOT'], '--headless', '--path', str(args.project.resolve()), '--audio-driver', 'Dummy',
               '--script', str(P / 'tests/progress_safety/nine_branch.gd'), '--', '--continue']
    result = run_owned(command, cwd=P, env=env, log_path=log_path, timeout=240)
    boundary_passed = result['passed']
    result['process_boundary_passed'] = boundary_passed
    result['passed'] = False  # Preliminary report can never claim gameplay success.
    # Persist cleanup/timeout/exit even if a crashed game left malformed runtime JSON.
    command_path.write_text(json.dumps(result, indent=2) + '\n', encoding='utf-8')
    try:
        runtime = json.loads(runtime_path.read_text(encoding='utf-8')) if runtime_path.exists() else {}
    except BaseException as exc:
        result['passed'] = False
        result['runtime_parse_error'] = type(exc).__name__ + ': ' + str(exc)
        runtime = {}
    try:
        result.update(mode=args.mode, actual_engine_PID=runtime.get('process_id'),
                      helper_sha256=sha(__file__), frozen_gameplay_helper_sha256=sha(P / 'tests/progress_safety/nine_branch.gd'),
                      runtime_sha256=sha(runtime_path) if runtime_path.exists() else None,
                      DLL_sha256=sha(args.project / 'bin/tb_reference.dll'), main_sha256=sha(args.project / 'reference/main.gd'),
                      Store_sha256=sha(args.project / 'reference/checkpoint_store.gd'),
                      resource_owner_check='external pinnedPS7 workspace/lease + TimeInit required before this ONE mode',
                      actual_engine_job_membership_observed=runtime.get('process_id') in result['observed_owned_PIDs'])
        result['passed'] = bool(boundary_passed and runtime.get('passed', False) and result['actual_engine_job_membership_observed'])
    except BaseException as exc:
        result['passed'] = False
        result['metadata_error'] = type(exc).__name__ + ': ' + str(exc)
    command_path.write_text(json.dumps(result, indent=2) + '\n', encoding='utf-8')
    print(json.dumps(result))
    raise SystemExit(0 if result['passed'] else 2)


if __name__ == '__main__':
    main()
